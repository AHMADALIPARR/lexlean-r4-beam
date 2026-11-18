defmodule MvmEx.Pool do
  @moduledoc """
  Standby pool, ported from mvm's pool model (`mvm_core::domain::pool`
  + the `mvmctl pool warm` behaviour).

  An unnamed run boots cold and leaves a standby VM of that image
  ready. The next matching run claims the standby instead of booting,
  and a fresh one is prepared behind it. Standbys are held within a
  host memory cap and released after idle minutes. A run that claims a
  standby must reach the guest in under 300 ms: a launch already over
  that when its command is about to be sent is refused there.
  """

  use GenServer

  alias MvmEx.{Instance, VM}

  @warm_claim_slo_ms 300
  @default_max_memory_mb 4096
  @default_idle_ms 20 * 60 * 1000

  defstruct standbys: %{}, memory_used_mb: 0, max_memory_mb: @default_max_memory_mb,
            idle_ms: @default_idle_ms, data_dir: nil, audit_path: nil, counter: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec warm_claim_slo_ms() :: pos_integer()
  def warm_claim_slo_ms, do: @warm_claim_slo_ms

  @spec warm(GenServer.server(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def warm(pool \\ __MODULE__, image, count) do
    GenServer.call(pool, {:warm, image, count})
  end

  @spec claim(GenServer.server(), String.t()) ::
          {:ok, pid(), non_neg_integer()} | {:error, :no_standby}
  def claim(pool \\ __MODULE__, image) do
    started = System.monotonic_time(:millisecond)
    result = GenServer.call(pool, {:claim, image})
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, pid} ->
        if elapsed <= @warm_claim_slo_ms do
          {:ok, pid, elapsed}
        else
          GenServer.cast(pool, {:return_standby, image, pid})
          {:error, :claim_too_slow}
        end

      other ->
        other
    end
  end

  @spec list(GenServer.server()) :: map()
  def list(pool \\ __MODULE__), do: GenServer.call(pool, :list)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_memory_mb: Keyword.get(opts, :max_memory_mb, @default_max_memory_mb),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      data_dir: Keyword.get(opts, :data_dir, Path.join(System.tmp_dir!(), "mvm-ex")),
      audit_path: Keyword.get(opts, :audit_path)
    }

    schedule_reap(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:warm, image, count}, _from, state) do
    memory_per = 256

    if state.memory_used_mb + count * memory_per > state.max_memory_mb do
      {:reply, {:error, "pool memory cap #{state.max_memory_mb} MB would be exceeded"}, state}
    else
      {ids, state} =
        Enum.reduce(1..count//1, {[], state}, fn _, {ids, st} ->
          id = "warm-#{st.counter + 1}"
          {:ok, instance} = Instance.new(%{"id" => id, "image" => image, "pool_id" => "default"})
          {:ok, instance} = Instance.transition(instance, :ready)
          {:ok, instance} = Instance.transition(instance, :warm)
          {:ok, pid} = VM.start_link(instance, data_dir: st.data_dir, audit_path: st.audit_path)
          entry = %{pid: pid, id: id, image: image, idle_since: System.monotonic_time(:millisecond)}
          standbys = Map.update(st.standbys, image, [entry], fn list -> [entry | list] end)
          {[id | ids], %{st | standbys: standbys, memory_used_mb: st.memory_used_mb + memory_per, counter: st.counter + 1}}
        end)

      {:reply, {:ok, Enum.reverse(ids)}, state}
    end
  end

  def handle_call({:claim, image}, _from, state) do
    case Map.get(state.standbys, image, []) do
      [] ->
        {:reply, {:error, :no_standby}, state}

      [entry | rest] ->
        standbys = Map.put(state.standbys, image, rest)
        {:reply, {:ok, entry.pid}, %{state | standbys: standbys, memory_used_mb: state.memory_used_mb - 256}}
    end
  end

  def handle_call(:list, _from, state) do
    summary =
      Map.new(state.standbys, fn {image, entries} ->
        {image, Enum.map(entries, & &1.id)}
      end)

    {:reply, %{standbys: summary, memory_used_mb: state.memory_used_mb, max_memory_mb: state.max_memory_mb}, state}
  end

  @impl true
  def handle_cast({:return_standby, image, pid}, state) do
    id = "warm-#{state.counter + 1}"
    entry = %{pid: pid, id: id, image: image, idle_since: System.monotonic_time(:millisecond)}
    standbys = Map.update(state.standbys, image, [entry], fn list -> [entry | list] end)
    {:noreply, %{state | standbys: standbys, memory_used_mb: state.memory_used_mb + 256, counter: state.counter + 1}}
  end

  @impl true
  def handle_info(:reap, state) do
    now = System.monotonic_time(:millisecond)

    {keep, reap} =
      Enum.reduce(state.standbys, {%{}, []}, fn {image, entries}, {keep, reap} ->
        {k, r} = Enum.split_with(entries, fn e -> now - e.idle_since < state.idle_ms end)
        {Map.put(keep, image, k), reap ++ r}
      end)

    Enum.each(reap, fn entry ->
      if Process.alive?(entry.pid), do: VM.stop(entry.pid)
    end)

    freed = length(reap) * 256
    schedule_reap(state)
    {:noreply, %{state | standbys: keep, memory_used_mb: max(state.memory_used_mb - freed, 0)}}
  end

  defp schedule_reap(state) do
    Process.send_after(self(), :reap, min(state.idle_ms, 60_000))
  end
end
