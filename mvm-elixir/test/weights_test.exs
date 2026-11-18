defmodule MvmEx.WeightsTest do
  use ExUnit.Case, async: false
  alias MvmEx.Weights

  @gpu_root Path.expand("../../gpu", __DIR__)

  test "inventory lists all six packs with their source models" do
    packs = Weights.inventory(@gpu_root)
    assert length(packs) == 6
    by_id = Map.new(packs, &{&1["id"], &1})

    assert by_id["v8"]["source_model"] =~ "GLM v8"
    assert by_id["v9"]["source_model"] =~ "GLLM v9"
    assert by_id["v10"]["source_model"] =~ "GLLM v10"
    assert by_id["v12_360m"]["source_model"] == "SmolLM2-360M-Instruct"
    assert by_id["v13_qwen3_0_6b"]["source_model"] == "Qwen3-0.6B"
    assert by_id["v13_qwen3_1_7b"]["source_model"] == "Qwen3-1.7B"

    # Receipts confirm the external teachers.
    assert by_id["v12_360m"]["receipt_hf_repo"] == "HuggingFaceTB/SmolLM2-360M-Instruct"
    assert by_id["v13_qwen3_0_6b"]["receipt_hf_repo"] == "Qwen/Qwen3-0.6B"
    assert by_id["v13_qwen3_1_7b"]["receipt_hf_repo"] == "Qwen/Qwen3-1.7B"
  end

  test "v8/v9/v10/v12 shards are present on disk; v13 pieces are not (branch mirrors)" do
    packs = Weights.inventory(@gpu_root)
    by_id = Map.new(packs, &{&1["id"], &1})

    assert by_id["v8"]["shards_present_count"] == 360
    assert by_id["v8"]["shards_present"] == true
    assert by_id["v9"]["shards_present_count"] == 25
    assert by_id["v10"]["shards_present_count"] == 73
    assert by_id["v12_360m"]["shards_present_count"] == 188
    assert by_id["v12_360m"]["shards_present"] == true
    assert by_id["v12_360m"]["mirror_branch"] == "weights-v12-360m"
    assert by_id["v13_qwen3_0_6b"]["shards_present_count"] == 0
    assert by_id["v13_qwen3_0_6b"]["mirror_branch"] == "weights-v13-qwen3-0.6b"
    assert by_id["v13_qwen3_1_7b"]["shards_present_count"] == 0
    assert by_id["v13_qwen3_1_7b"]["mirror_branch"] == "weights-v13-qwen3-1.7b"
  end

  test "v12 pack verifies: every shard hash matches its manifest" do
    assert {:ok, result} = Weights.verify_pack(@gpu_root, "v12_360m")
    assert result["verified"] == true
    assert result["ok"] == 188
    assert result["missing"] == []
    assert result["bad"] == []
  end

  test "v9 pack verifies: every shard hash matches its manifest" do
    assert {:ok, result} = Weights.verify_pack(@gpu_root, "v9")
    assert result["verified"] == true
    assert result["ok"] == 25
    assert result["missing"] == []
    assert result["bad"] == []
  end

  test "v10 data shards verify; parity set is present per the stitch manifest" do
    assert {:ok, result} = Weights.verify_pack(@gpu_root, "v10")
    assert result["verified"] == true
    assert result["ok"] == 73
    parity = Path.wildcard(Path.join(@gpu_root, "weights/v10/parity_*.bin"))
    assert length(parity) == 37
  end

  test "v8 stitches to the exact container hash in its manifest" do
    out = Path.join(System.tmp_dir!(), "mvm-ex-v8-test.uorlut")
    assert {:ok, result} = Weights.stitch_v8(@gpu_root, out)
    assert result["match"] == true
    assert result["bytes"] == 188_728_472
    assert result["sha256"] == "34259da95f7760d0d8633ff53afd6d6cce9a89d98c3e5bd0b11ff862ceee5e48"
    File.rm(out)
  end

  test "tokenizer hash matches the hash stated in the gpu README" do
    assert {:ok, info} = Weights.tokenizer_sha(@gpu_root)
    assert info["sha256"] == info["readme_claimed_sha256"]
    assert info["sha256"] == "d36d3e8700a123e620012df77de195f244fbdb4d05d9e1aa7e77fa9407590f89"
  end

  test "short.uorlut carries the UORLUT01 magic" do
    assert {:ok, info} = Weights.short_uorlut_info(@gpu_root)
    assert info["magic"] == "UORLUT01"
    assert info["bytes"] == 2_156_480
  end

  test "unknown pack is an error, not a silent empty result" do
    assert {:error, _} = Weights.verify_pack(@gpu_root, "nope")
  end
end
