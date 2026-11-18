defmodule MvmEx.VM do
  @moduledoc """
  One microVM session.

  Ported from mvm's runtime lifecycle (`mvm_runtime` + `mvm_hostd`
  supervisor), with the backend split out: mvm boots a real hypervisor
  guest (Firecracker on Linux with /dev/kvm, HVF/libkrun on macOS).
  This VM has no /dev/kvm, so the software backend runs the guest as an
  isolated OS process instead — the same shape the owner ordered for
  this box in 2026-11-04 (a software container CPU; a KVM guest is only
  an optional extra wrap on hosts that have one).

  Software-backend isolation, stated plainly:
  - the guest process runs with a scrubbed environment (PATH only),
    a per-instance jail directory as its working directory, and a
    wall-clock timeout enforced by the host;
  - commands run through the BEAM spawn port (`/bin/sh -c 'exec ...'`),
    so they must be external binaries (or an explicit `sh -c '...'`
    wrapper); shell builtins such as `exit` are not available bare;
  - read-only mounts are symlinks into the jail, so the guest can read
    a weight pack but cannot write it;
  - the guest has no vsock. Egress goes through `MvmEx.Egress` on the
    host; this backend cannot prevent a guest process from opening a
    socket directly the way a hypervisor with no network device can.
    Direct egress from a software-backend guest is out of scope here
    and is recorded in STATUS.md, not hidden.
  """

  use GenServer

  alias MvmEx.{Audit, Gate, Instance}

  @output_cap 262_144

  defstruct [:instance, :port, :jail, :gate, :audit_path, :data_dir, :mounts,
             output: "", exit_status: nil, caller: nil, timer: nil, backend: :software]

  @spec start_link(Instance.t(), keyword()) :: GenServer.on_start()
  def start_link(%Instance{} = instance, opts \\ []) do
    GenServer.start_link(__MODULE__, {instance, opts})
  end

  @spec exec(pid(), String.t(), pos_integer()) ::
          {:ok, %{output: String.t(), exit_status: integer()}}
          | {:error, term()}
  def exec(pid, command, timeout_ms \\ 30_000) do
    GenServer.call(pid, {:exec, command, timeout_ms}, timeout_ms + 5_000)
  end

  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.call(pid, :stop)

  @impl true
  def init({instance, opts}) do
    data_dir = Keyword.get(opts, :data_dir, Path.join(System.tmp_dir!(), "mvm-ex"))
    jail = Path.join([data_dir, "jails", instance.id])
    File.mkdir_p!(jail)
    mounts = Keyword.get(opts, :mounts, [])

    Enum.each(mounts, fn {host_path, guest_name} ->
      link = Path.join(jail, guest_name)
      File.rm(link)
      File.ln_s(host_path, link)
    end)

    {:ok, instance} =
      case instance.status do
        :created -> Instance.transition(instance, :ready)
        status when status in [:ready, :warm] -> {:ok, instance}
        _ -> {:error, "cannot start a VM from status #{instance.status}"}
      end

    state = %__MODULE__{
      instance: instance,
      jail: jail,
      gate: Keyword.get(opts, :gate, Gate.new()),
      audit_path: Keyword.get(opts, :audit_path),
      data_dir: data_dir,
      mounts: mounts
    }

    audit(state, "vm_created", %{"instance" => instance.id, "image" => instance.image, "backend" => "software"})
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Instance.to_map(state.instance), state}
  end

  def handle_call(:stop, _from, state) do
    state = kill_port(state)

    instance =
      case Instance.transition(state.instance, :stopped) do
        {:ok, inst} -> inst
        {:error, _} -> state.instance
      end

    audit(state, "vm_stopped", %{"instance" => instance.id})
    {:stop, :normal, :ok, %{state | instance: instance}}
  end

  def handle_call({:exec, command, timeout_ms}, from, state) do
    case Gate.evaluate(state.gate, command) do
      {:blocked, pattern, category} ->
        audit(state, "exec_blocked", %{
          "instance" => state.instance.id,
          "pattern" => pattern,
          "category" => category
        })

        {:reply, {:error, {:blocked, pattern, category}}, state}

      {:requires_approval, pattern, category} ->
        audit(state, "exec_requires_approval", %{
          "instance" => state.instance.id,
          "pattern" => pattern,
          "category" => category
        })

        {:reply, {:error, {:requires_approval, pattern, category}}, state}

      {:allow, _logs} ->
        case transition_to_running(state.instance) do
          {:error, _} = err ->
            {:reply, err, state}

          {:ok, instance} ->
            {:ok, instance} = Instance.set_readiness(instance, :services_starting)
            port = Port.open({:spawn, command}, [:binary, :exit_status, {:cd, state.jail}, {:env, [{~c"PATH", ~c"/usr/bin:/bin"}]}])
            timer = Process.send_after(self(), {:exec_timeout, port}, timeout_ms)
            audit(state, "exec_started", %{"instance" => instance.id, "command" => command})
            {:noreply, %{state | instance: instance, port: port, output: "", exit_status: nil, caller: from, timer: timer}}
        end
    end
  end

  defp transition_to_running(%Instance{status: status} = instance)
       when status in [:ready, :warm],
       do: Instance.transition(instance, :running)

  defp transition_to_running(%Instance{status: :running} = instance), do: {:ok, instance}
  defp transition_to_running(%Instance{status: other}), do: {:error, "cannot exec while instance is #{other}"}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = state.output <> data
    output = if byte_size(output) > @output_cap, do: binary_part(output, 0, @output_cap) <> "\n[output truncated at 256 KiB]\n", else: output
    {:noreply, %{state | output: output}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:ok, instance} = Instance.set_readiness(state.instance, :services_ready)
    audit(state, "exec_finished", %{"instance" => instance.id, "exit_status" => status})
    GenServer.reply(state.caller, {:ok, %{output: state.output, exit_status: status}})
    {:noreply, %{state | instance: instance, port: nil, caller: nil, timer: nil}}
  end

  def handle_info({:exec_timeout, port}, %{port: port} = state) do
    state = kill_port(state)
    audit(state, "exec_timeout", %{"instance" => state.instance.id})
    GenServer.reply(state.caller, {:error, :timeout})
    {:noreply, %{state | port: nil, caller: nil, timer: nil}}
  end

  def handle_info({:exec_timeout, _port}, state), do: {:noreply, state}
  def handle_info({_port, _msg}, state), do: {:noreply, state}

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Port.close(state.port)
    %{state | port: nil, timer: nil}
  end

  defp audit(%{audit_path: nil}, _event, _data), do: :ok

  defp audit(%{audit_path: path} = _state, event, data) do
    Audit.append_to_file(path, event, data)
  end
end
