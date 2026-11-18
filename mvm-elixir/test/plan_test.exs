defmodule MvmEx.PlanTest do
  use ExUnit.Case, async: true
  alias MvmEx.Plan

  @attrs %{"id" => "p1", "image" => "alpine", "command" => "uname -s", "cpus" => 1, "memory_mb" => 256, "timeout_s" => 30}

  test "synthesize validates and digests" do
    assert {:ok, plan} = Plan.synthesize(@attrs)
    assert byte_size(plan.digest) == 64
    assert plan.digest == Plan.digest(plan)
  end

  test "synthesize rejects bad fields" do
    assert {:error, _} = Plan.synthesize(Map.delete(@attrs, "command"))
    assert {:error, _} = Plan.synthesize(Map.put(@attrs, "cpus", 0))
    assert {:error, _} = Plan.synthesize(Map.put(@attrs, "timeout_s", 99999))
    assert {:error, _} = Plan.synthesize(Map.put(@attrs, "args", ["ok", 1]))
  end

  test "sign then verify round-trips; tampering fails" do
    {:ok, plan} = Plan.synthesize(@attrs)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    assert {:ok, signed} = Plan.sign(plan, priv)
    assert Plan.verify(signed, pub)
    tampered = %{signed | command: "uname -a"}
    refute Plan.verify(tampered, pub)
    {pub2, _} = :crypto.generate_key(:eddsa, :ed25519)
    refute Plan.verify(signed, pub2)
  end

  test "from_map rejects a stored digest that does not match the body" do
    {:ok, plan} = Plan.synthesize(@attrs)
    map = Plan.to_map(plan) |> Map.put("digest", String.duplicate("0", 64))
    assert {:error, _} = Plan.from_map(map)
  end

  test "from_map accepts an honest round-trip" do
    {:ok, plan} = Plan.synthesize(@attrs)
    assert {:ok, back} = Plan.from_map(Plan.to_map(plan))
    assert back.digest == plan.digest
  end
end
