defmodule MvmEx.Agent do
  @moduledoc """
  Guest/host agent protocol, ported from mvm's
  `mvm_core::domain::agent` (`AgentRequest` / `AgentResponse`).

  In mvm the agent speaks over vsock between the guest and the host
  supervisor. Here the same request shapes are handled in-process by
  the BEAM node: the wire format is one canonical JSON object with a
  `"kind"` field, and `handle/1` dispatches it against the local pool
  and VM registry. Production mvm additionally signs reconcile
  payloads (`ReconcileSigned`); this port accepts unsigned reconcile
  only in dev mode and rejects it otherwise, exactly like the Rust
  `Reconcile` (unsigned, dev mode only) variant.
  """

  alias MvmEx.{Instance, Pool, VM}

  @spec handle(map()) :: {:ok, map()} | {:error, String.t()}
  def handle(%{"kind" => "node_info"}) do
    {:ok,
     %{
       "kind" => "node_info",
       "backend" => "software",
       "kvm_available" => MvmEx.kvm_available?(),
       "otp" => to_string(:erlang.system_info(:otp_release)),
       "elixir" => System.version()
     }}
  end

  def handle(%{"kind" => "node_stats"}) do
    %{standbys: standbys, memory_used_mb: used, max_memory_mb: max} = Pool.list()
    {:ok, %{"kind" => "node_stats", "standbys" => standbys, "memory_used_mb" => used, "max_memory_mb" => max}}
  end

  def handle(%{"kind" => "tenant_list"}) do
    {:ok, %{"kind" => "tenant_list", "tenants" => ["default"]}}
  end

  def handle(%{"kind" => "instance_list", "tenant_id" => _tenant}) do
    %{standbys: standbys} = Pool.list()
    instances = Enum.flat_map(standbys, fn {_image, ids} -> ids end)
    {:ok, %{"kind" => "instance_list", "instances" => instances}}
  end

  def handle(%{"kind" => "wake_instance", "image" => image}) when is_binary(image) do
    case Pool.claim(image) do
      {:ok, _pid, ms} -> {:ok, %{"kind" => "wake_result", "success" => true, "claim_ms" => ms}}
      {:error, reason} -> {:ok, %{"kind" => "wake_result", "success" => false, "error" => to_string(reason)}}
    end
  end

  def handle(%{"kind" => "instance_action", "action" => "start", "id" => id, "image" => image}) do
    with {:ok, instance} <- Instance.new(%{"id" => id, "image" => image}),
         {:ok, pid} <- VM.start_link(instance) do
      {:ok, %{"kind" => "instance_action_result", "success" => true, "new_status" => "ready", "pid" => inspect(pid)}}
    else
      {:error, reason} -> {:ok, %{"kind" => "instance_action_result", "success" => false, "new_status" => "created", "error" => to_string(reason)}}
    end
  end

  def handle(%{"kind" => "reconcile", "dev_mode" => true}) do
    {:ok, %{"kind" => "reconcile_result", "applied" => 0, "note" => "dev-mode unsigned reconcile accepted; no desired state supplied"}}
  end

  def handle(%{"kind" => "reconcile"}) do
    {:error, "unsigned reconcile requires dev mode; production reconcile must be signed"}
  end

  def handle(%{"kind" => kind}) do
    {:error, "unknown agent request kind #{kind}"}
  end

  def handle(_), do: {:error, "agent request needs a kind field"}
end
