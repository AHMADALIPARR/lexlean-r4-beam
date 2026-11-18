defmodule MvmEx.Instance do
  @moduledoc """
  Instance lifecycle, ported from mvm's `mvm_core::domain::instance`.

  `status` is the coarse lifecycle (created/ready/running/warm/sleeping/
  stopped/destroyed). `readiness` is the finer "is this VM usable yet?"
  signal that composes alongside it and never moves the lifecycle on
  its own: a running instance can be agent_connecting,
  services_starting, services_ready or degraded.
  """

  @statuses [:created, :ready, :running, :warm, :sleeping, :stopped, :destroyed]
  @readiness [:agent_connecting, :services_starting, :services_ready, :degraded]

  @transitions %{
    created: [:ready, :destroyed],
    ready: [:running, :warm, :stopped, :destroyed],
    running: [:sleeping, :stopped, :destroyed],
    warm: [:running, :stopped, :destroyed],
    sleeping: [:running, :warm, :stopped, :destroyed],
    stopped: [:ready, :destroyed],
    destroyed: []
  }

  @enforce_keys [:id, :image]
  defstruct [
    :id,
    :image,
    tenant_id: "default",
    pool_id: nil,
    status: :created,
    readiness: :agent_connecting,
    cpus: 1,
    memory_mb: 256,
    command: nil,
    created_at: nil,
    started_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          tenant_id: String.t(),
          pool_id: String.t() | nil,
          status: atom(),
          readiness: atom(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          command: String.t() | nil,
          created_at: String.t() | nil,
          started_at: String.t() | nil
        }

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec readiness_values() :: [atom()]
  def readiness_values, do: @readiness

  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- req(attrs, "id"),
         {:ok, image} <- req(attrs, "image") do
      {:ok,
       %__MODULE__{
         id: id,
         image: image,
         tenant_id: Map.get(attrs, "tenant_id", "default"),
         pool_id: Map.get(attrs, "pool_id"),
         cpus: Map.get(attrs, "cpus", 1),
         memory_mb: Map.get(attrs, "memory_mb", 256),
         command: Map.get(attrs, "command"),
         created_at: utc_now()
       }}
    end
  end

  @spec transition(t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def transition(%__MODULE__{status: from} = inst, to) when is_atom(to) do
    allowed = Map.get(@transitions, from, [])

    if to in allowed do
      inst = %{inst | status: to}
      inst = if to == :running, do: %{inst | started_at: utc_now()}, else: inst
      {:ok, inst}
    else
      {:error, "illegal instance transition #{from} -> #{to}"}
    end
  end

  @spec set_readiness(t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def set_readiness(%__MODULE__{} = inst, readiness) when is_atom(readiness) do
    if readiness in @readiness do
      {:ok, %{inst | readiness: readiness}}
    else
      {:error, "unknown readiness #{inspect(readiness)}"}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = inst) do
    %{
      "id" => inst.id,
      "image" => inst.image,
      "tenant_id" => inst.tenant_id,
      "pool_id" => inst.pool_id,
      "status" => Atom.to_string(inst.status),
      "readiness" => Atom.to_string(inst.readiness),
      "cpus" => inst.cpus,
      "memory_mb" => inst.memory_mb,
      "command" => inst.command,
      "created_at" => inst.created_at,
      "started_at" => inst.started_at
    }
  end

  defp req(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "instance field #{key} must be a non-empty string"}
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
