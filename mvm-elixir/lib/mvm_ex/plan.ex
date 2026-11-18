defmodule MvmEx.Plan do
  @moduledoc """
  Execution plan, ported from mvm's `mvm_core::plan`.

  In mvm, every launch is described by an execution plan that `mvmctl`
  signs, checks and records in a hash-chained audit log *before* the VM
  boots. Synthesis produces an unsigned plan and confers no authority;
  signing and admission still gate execution. That separation is kept
  here: `synthesize/1` validates and digests, `sign/2` attaches an
  Ed25519 signature, `verify/2` checks it.
  """

  alias MvmEx.Json

  @enforce_keys [:id, :image, :command]
  defstruct [
    :id,
    :image,
    :command,
    cpus: 1,
    memory_mb: 256,
    timeout_s: 30,
    args: [],
    egress_allowlist: [],
    secret_placeholders: [],
    env: %{},
    digest: nil,
    signature: nil,
    signer: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          command: String.t(),
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          timeout_s: pos_integer(),
          args: [String.t()],
          egress_allowlist: [String.t()],
          secret_placeholders: [String.t()],
          env: %{String.t() => String.t()},
          digest: String.t() | nil,
          signature: String.t() | nil,
          signer: String.t() | nil
        }

  @spec synthesize(map()) :: {:ok, t()} | {:error, String.t()}
  def synthesize(attrs) when is_map(attrs) do
    with {:ok, id} <- require_string(attrs, "id"),
         {:ok, image} <- require_string(attrs, "image"),
         {:ok, command} <- require_string(attrs, "command"),
         {:ok, cpus} <- require_int(attrs, "cpus", 1, 1, 64),
         {:ok, memory_mb} <- require_int(attrs, "memory_mb", 256, 64, 65_536),
         {:ok, timeout_s} <- require_int(attrs, "timeout_s", 30, 1, 3600),
         {:ok, args} <- require_string_list(attrs, "args", []),
         {:ok, egress} <- require_string_list(attrs, "egress_allowlist", []),
         {:ok, placeholders} <- require_string_list(attrs, "secret_placeholders", []),
         {:ok, env} <- require_string_map(attrs, "env", %{}) do
      plan = %__MODULE__{
        id: id,
        image: image,
        command: command,
        cpus: cpus,
        memory_mb: memory_mb,
        timeout_s: timeout_s,
        args: args,
        egress_allowlist: egress,
        secret_placeholders: placeholders,
        env: env
      }

      {:ok, %{plan | digest: digest(plan)}}
    end
  end

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = plan) do
    plan
    |> to_map()
    |> Map.delete("digest")
    |> Map.delete("signature")
    |> Map.delete("signer")
    |> Json.canonical()
    |> sha256_hex()
  end

  @spec sign(t(), binary()) :: {:ok, t()} | {:error, String.t()}
  def sign(%__MODULE__{digest: digest} = plan, priv) when is_binary(priv) do
    if byte_size(priv) != 32 do
      {:error, "ed25519 private key must be 32 bytes"}
    else
      sig = :crypto.sign(:eddsa, :none, digest, [priv, :ed25519])
      pub = ed_pubkey(priv)
      {:ok, %{plan | signature: Base.encode16(sig, case: :lower), signer: pub}}
    end
  end

  @spec verify(t(), binary()) :: boolean()
  def verify(%__MODULE__{digest: digest, signature: sig_hex} = plan, pub)
      when is_binary(digest) and is_binary(sig_hex) and is_binary(pub) do
    with true <- digest == digest(plan),
         {:ok, sig} <- Base.decode16(sig_hex, case: :lower),
         true <- byte_size(sig) == 64,
         true <- byte_size(pub) == 32 do
      :crypto.verify(:eddsa, :none, digest, sig, [pub, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def verify(_plan, _pub), do: false

  @spec ed_pubkey(binary()) :: String.t()
  def ed_pubkey(priv) when is_binary(priv) and byte_size(priv) == 32 do
    {pub, _} = :crypto.generate_key(:eddsa, :ed25519, priv)
    Base.encode16(pub, case: :lower)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = plan) do
    %{
      "id" => plan.id,
      "image" => plan.image,
      "command" => plan.command,
      "cpus" => plan.cpus,
      "memory_mb" => plan.memory_mb,
      "timeout_s" => plan.timeout_s,
      "args" => plan.args,
      "egress_allowlist" => plan.egress_allowlist,
      "secret_placeholders" => plan.secret_placeholders,
      "env" => plan.env,
      "digest" => plan.digest,
      "signature" => plan.signature,
      "signer" => plan.signer
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    with {:ok, plan} <- synthesize(map) do
      plan = %{
        plan
        | digest: Map.get(map, "digest"),
          signature: Map.get(map, "signature"),
          signer: Map.get(map, "signer")
      }

      if plan.digest == digest(plan) do
        {:ok, plan}
      else
        {:error, "plan digest mismatch: stored digest does not match plan body"}
      end
    end
  end

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "plan field #{key} must be a non-empty string"}
    end
  end

  defp require_int(attrs, key, default, min, max) do
    case Map.get(attrs, key, default) do
      v when is_integer(v) and v >= min and v <= max -> {:ok, v}
      _ -> {:error, "plan field #{key} must be an integer in #{min}..#{max}"}
    end
  end

  defp require_string_list(attrs, key, default) do
    case Map.get(attrs, key, default) do
      v when is_list(v) and is_list(v) ->
        if Enum.all?(v, &is_binary/1),
          do: {:ok, v},
          else: {:error, "plan field #{key} must be a list of strings"}

      _ ->
        {:error, "plan field #{key} must be a list of strings"}
    end
  end

  defp require_string_map(attrs, key, default) do
    case Map.get(attrs, key, default) do
      v when is_map(v) ->
        if Enum.all?(v, fn {k, val} -> is_binary(k) and is_binary(val) end),
          do: {:ok, v},
          else: {:error, "plan field #{key} must be a map of strings"}

      _ ->
        {:error, "plan field #{key} must be a map of strings"}
    end
  end
end
