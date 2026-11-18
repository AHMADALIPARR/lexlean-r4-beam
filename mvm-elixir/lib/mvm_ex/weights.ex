defmodule MvmEx.Weights do
  @moduledoc """
  Inventory and verification for the sliced weight packs in `gpu/weights`.

  The packs in this clone, as read from their manifests and receipts
  (not assumed):

  - v8  `uor-r4-glm-v8-2b` — 188,728,472 B in 360 x 512 KiB parts,
    UORLUT01, HF `caseyallard/uor-r4-store`. Native UOR-R4 GLM.
  - v9  `UORGLLM9` — 12,895,254 B in 25 x 512 KiB parts.
    Native UOR-R4 compositional GLLM.
  - v10 `UORR4V12` — 75,684,407 B in 73 x 1 MiB shards (+37 parity
    shards, 82,427,606 B with parity per the gpu README). Native
    UOR-R4 GLLM, 16L 256D.
  - v12 `360m` — SmolLM2-360M-Instruct (receipt `hf_repo`
    `HuggingFaceTB/SmolLM2-360M-Instruct`), 196,669,221 B in 188
    shards. Pieces ARE in this repo (`gpu/weights/v12_360m/`), copied
    from branch `weights-v12-360m` — the size fit is why v12 made the
    cut and v13 did not.
  - v13 `qwen3-0.6b` — Qwen/Qwen3-0.6B, 429,484,190 B in 410 pieces.
    Pieces live on branch `weights-v13-qwen3-0.6b`, NOT in this repo.
  - v13 `qwen3-1.7b` — Qwen/Qwen3-1.7B, 1,140,250,782 B in 1088
    pieces. Pieces live on branch `weights-v13-qwen3-1.7b`, NOT in this repo.

  `verify_pack/1` hashes every shard present on disk against its
  manifest entry and reports missing pieces by name instead of
  pretending they are here. `stitch_v8/2` reassembles the v8 parts and
  checks the container SHA-256 from the manifest.
  """

  alias MvmEx.Json

  @packs [
    %{
      id: "v8",
      manifest: "weights/manifest.json",
      receipt: nil,
      source_model: "UOR-R4 GLM v8 (uor-r4-glm-v8-2b)",
      source_hf: "caseyallard/uor-r4-store",
      kind: "uorlut"
    },
    %{
      id: "v9",
      manifest: "weights/v9/manifest.json",
      receipt: nil,
      source_model: "UOR-R4 GLLM v9 (UORGLLM9)",
      source_hf: nil,
      kind: "uorgllm"
    },
    %{
      id: "v10",
      manifest: "weights/v10/manifest.json",
      receipt: "receipts/rtx5090_gllm_v10_receipt.json",
      source_model: "UOR-R4 GLLM v10 (UORR4V12)",
      source_hf: nil,
      kind: "shards"
    },
    %{
      id: "v12_360m",
      manifest: "weights/v12_360m/manifest.json",
      receipt: "weights/v12_360m/receipt_v12.json",
      source_model: "SmolLM2-360M-Instruct",
      source_hf: "HuggingFaceTB/SmolLM2-360M-Instruct",
      kind: "shards",
      mirror_branch: "weights-v12-360m"
    },
    %{
      id: "v13_qwen3_0_6b",
      manifest: "weights/v13_qwen3_0_6b/manifest.json",
      receipt: "receipts/rtx4090_holo_v13_qwen3_0_6b_receipt.json",
      source_model: "Qwen3-0.6B",
      source_hf: "Qwen/Qwen3-0.6B",
      kind: "pieces",
      mirror_branch: "weights-v13-qwen3-0.6b"
    },
    %{
      id: "v13_qwen3_1_7b",
      manifest: "weights/v13_qwen3_1_7b/manifest.json",
      receipt: "receipts/rtx4090_holo_v13_qwen3_1_7b_receipt.json",
      source_model: "Qwen3-1.7B",
      source_hf: "Qwen/Qwen3-1.7B",
      kind: "pieces",
      mirror_branch: "weights-v13-qwen3-1.7b"
    }
  ]

  @spec pack_ids() :: [String.t()]
  def pack_ids, do: Enum.map(@packs, & &1.id)

  @spec gpu_root() :: {:ok, Path.t()} | {:error, String.t()}
  def gpu_root do
    candidates =
      [
        System.get_env("MVM_GPU_ROOT"),
        Path.expand("../gpu", File.cwd!()),
        Path.expand("gpu", File.cwd!()),
        Path.expand("~/workspace/lexlean-r4-beam/gpu")
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find(candidates, &File.dir?/1) do
      nil -> {:error, "gpu directory not found; set MVM_GPU_ROOT"}
      dir -> {:ok, dir}
    end
  end

  @spec inventory(Path.t()) :: [map()]
  def inventory(gpu_root) do
    Enum.map(@packs, fn pack ->
      manifest_path = Path.join(gpu_root, pack.manifest)
      base = %{
        "id" => pack.id,
        "source_model" => pack.source_model,
        "source_hf" => pack.source_hf,
        "kind" => pack.kind,
        "manifest" => pack.manifest,
        "manifest_present" => File.exists?(manifest_path),
        "mirror_branch" => Map.get(pack, :mirror_branch)
      }

      case read_manifest(manifest_path) do
        {:ok, manifest} ->
          base
          |> Map.merge(%{
            "format" => Map.get(manifest, "format"),
            "schema" => Map.get(manifest, "schema"),
            "total_bytes" => Map.get(manifest, "total_bytes"),
            "shard_count" => shard_count(manifest),
            "container_sha256" => Map.get(manifest, "container_sha256") || Map.get(manifest, "sha256"),
            "shards_present" => shards_present?(gpu_root, pack, manifest),
            "shards_present_count" => shards_present_count(gpu_root, pack, manifest)
          })
          |> put_receipt_hf(gpu_root, pack)

        {:error, reason} ->
          Map.put(base, "manifest_error", reason)
      end
    end)
  end

  @spec verify_pack(Path.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def verify_pack(gpu_root, pack_id) do
    pack = Enum.find(@packs, &(&1.id == pack_id))

    if is_nil(pack) do
      {:error, "unknown pack #{pack_id}; known: #{Enum.join(pack_ids(), ", ")}"}
    else
      with {:ok, manifest} <- read_manifest(Path.join(gpu_root, pack.manifest)) do
        entries = shard_entries(manifest)

        results =
          Enum.map(entries, fn entry ->
            path = shard_path(gpu_root, pack, entry)
            expected = entry["sha256"]
            verify_shard(path, expected, entry)
          end)

        ok = Enum.count(results, &(&1["status"] == "ok"))
        bad = Enum.filter(results, &(&1["status"] == "bad"))
        missing = Enum.filter(results, &(&1["status"] == "missing"))

        {:ok,
         %{
           "pack" => pack_id,
           "total" => length(results),
           "ok" => ok,
           "bad" => Enum.map(bad, & &1["file"]),
           "missing" => Enum.map(missing, & &1["file"]),
           "verified" => bad == [] and missing == []
         }}
      end
    end
  end

  @spec stitch_v8(Path.t(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  def stitch_v8(gpu_root, out_path) do
    with {:ok, manifest} <- read_manifest(Path.join(gpu_root, "weights/manifest.json")) do
      parts =
        manifest["shards"]
        |> Enum.sort_by(& &1["index"])
        |> Enum.map(fn e -> Path.join(gpu_root, e["path"]) end)

      missing = Enum.reject(parts, &File.exists?/1)

      if missing != [] do
        {:error, "v8 stitch missing #{length(missing)} parts, first: #{hd(missing)}"}
      else
        File.mkdir_p!(Path.dirname(out_path))
        {:ok, out} = File.open(out_path, [:write, :binary])
        hash = :crypto.hash_init(:sha256)
        total = 0

        {hash, total} =
          Enum.reduce(parts, {hash, total}, fn part, {h, t} ->
            {:ok, data} = File.read(part)
            IO.binwrite(out, data)
            {:crypto.hash_update(h, data), t + byte_size(data)}
          end)

        File.close(out)
        digest = :crypto.hash_final(hash) |> Base.encode16(case: :lower)

        {:ok,
         %{
           "out" => out_path,
           "bytes" => total,
           "expected_bytes" => manifest["total_bytes"],
           "sha256" => digest,
           "expected_sha256" => manifest["sha256"],
           "match" => total == manifest["total_bytes"] and digest == manifest["sha256"]
         }}
      end
    end
  end

  @spec short_uorlut_info(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def short_uorlut_info(gpu_root) do
    path = Path.join(gpu_root, "short.uorlut")

    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, magic} = File.open(path, [:read, :binary], fn f -> IO.binread(f, 8) end)
        {:ok, %{"path" => "short.uorlut", "bytes" => size, "magic" => magic, "sha256" => sha256_file(path)}}

      {:error, reason} ->
        {:error, "short.uorlut unreadable: #{inspect(reason)}"}
    end
  end

  @spec tokenizer_sha(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def tokenizer_sha(gpu_root) do
    path = Path.join(gpu_root, "tokenizer.json")

    case File.exists?(path) do
      true ->
        {:ok,
         %{
           "path" => "tokenizer.json",
           "sha256" => sha256_file(path),
           "readme_claimed_sha256" => "d36d3e8700a123e620012df77de195f244fbdb4d05d9e1aa7e77fa9407590f89"
         }}

      false ->
        {:error, "tokenizer.json missing"}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, content} -> Json.decode(content)
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp shard_entries(manifest) do
    cond do
      is_list(Map.get(manifest, "shards")) -> manifest["shards"]
      is_list(Map.get(manifest, "pieces")) -> manifest["pieces"]
      true -> []
    end
  end

  defp shard_count(manifest), do: length(shard_entries(manifest))

  defp shard_path(gpu_root, pack, entry) do
    rel =
      cond do
        is_binary(entry["path"]) -> entry["path"]
        is_binary(entry["file"]) -> Path.join("weights/#{pack.id}", entry["file"])
        true -> ""
      end

    # v8/v9/v10 manifest paths are relative to gpu/; v12/v13 piece files
    # are relative to their pack dir.
    if String.starts_with?(rel, "weights/") do
      Path.join(gpu_root, rel)
    else
      Path.join([gpu_root, "weights", pack.id, rel])
    end
  end

  defp shards_present?(gpu_root, pack, manifest) do
    manifest |> shard_entries() |> Enum.all?(fn e -> File.exists?(shard_path(gpu_root, pack, e)) end)
  end

  defp shards_present_count(gpu_root, pack, manifest) do
    manifest
    |> shard_entries()
    |> Enum.count(fn e -> File.exists?(shard_path(gpu_root, pack, e)) end)
  end

  defp verify_shard(path, expected, entry) do
    file = Map.get(entry, "file") || Map.get(entry, "path") || path

    case File.exists?(path) do
      false ->
        %{"file" => file, "status" => "missing"}

      true ->
        actual = sha256_file(path)
        %{"file" => file, "status" => if(actual == expected, do: "ok", else: "bad"), "expected" => expected, "actual" => actual}
    end
  end

  defp put_receipt_hf(base, gpu_root, pack) do
    if pack.receipt do
      case read_manifest(Path.join(gpu_root, pack.receipt)) do
        {:ok, receipt} ->
          hf = Map.get(receipt, "hf_repo") || base["source_hf"]
          Map.put(base, "receipt_hf_repo", hf)

        {:error, _} ->
          base
      end
    else
      base
    end
  end

  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!([:binary], 1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, h -> :crypto.hash_update(h, chunk) end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
