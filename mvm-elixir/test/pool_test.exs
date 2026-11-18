defmodule MvmEx.PoolTest do
  use ExUnit.Case, async: true
  alias MvmEx.Pool

  test "warm standbys can be claimed inside the 300 ms SLO" do
    {:ok, pool} = Pool.start_link(name: nil, data_dir: Path.join(System.tmp_dir!(), "mvm-ex-test-pool"))
    assert {:ok, [_id]} = Pool.warm(pool, "alpine", 1)
    assert {:ok, _pid, ms} = Pool.claim(pool, "alpine")
    assert ms <= Pool.warm_claim_slo_ms()
    assert {:error, :no_standby} = Pool.claim(pool, "alpine")
  end

  test "memory cap refuses warming past the limit" do
    {:ok, pool} = Pool.start_link(name: nil, max_memory_mb: 256, data_dir: Path.join(System.tmp_dir!(), "mvm-ex-test-pool"))
    assert {:ok, [_]} = Pool.warm(pool, "alpine", 1)
    assert {:error, _} = Pool.warm(pool, "alpine", 1)
  end

  test "idle standbys are reaped after the idle window" do
    {:ok, pool} = Pool.start_link(name: nil, idle_ms: 100, data_dir: Path.join(System.tmp_dir!(), "mvm-ex-test-pool"))
    assert {:ok, [_id]} = Pool.warm(pool, "alpine", 1)
    Process.sleep(250)
    assert %{standbys: %{"alpine" => []}} = Pool.list(pool)
  end
end
