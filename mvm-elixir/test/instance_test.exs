defmodule MvmEx.InstanceTest do
  use ExUnit.Case, async: true
  alias MvmEx.Instance

  test "lifecycle transitions follow the mvm state machine" do
    {:ok, inst} = Instance.new(%{"id" => "i1", "image" => "alpine"})
    assert inst.status == :created
    assert {:ok, inst} = Instance.transition(inst, :ready)
    assert {:ok, inst} = Instance.transition(inst, :warm)
    assert {:ok, inst} = Instance.transition(inst, :running)
    assert inst.started_at != nil
    assert {:ok, inst} = Instance.transition(inst, :sleeping)
    assert {:ok, inst} = Instance.transition(inst, :running)
    assert {:ok, inst} = Instance.transition(inst, :stopped)
    assert {:ok, inst} = Instance.transition(inst, :destroyed)
    assert {:error, _} = Instance.transition(inst, :running)
  end

  test "illegal transitions are rejected" do
    {:ok, inst} = Instance.new(%{"id" => "i1", "image" => "alpine"})
    assert {:error, _} = Instance.transition(inst, :running)
    assert {:error, _} = Instance.transition(inst, :stopped)
  end

  test "readiness is independent of lifecycle" do
    {:ok, inst} = Instance.new(%{"id" => "i1", "image" => "alpine"})
    assert {:ok, inst} = Instance.transition(inst, :ready)
    assert {:ok, inst} = Instance.transition(inst, :running)
    assert {:ok, inst} = Instance.set_readiness(inst, :services_ready)
    assert inst.status == :running
    assert {:error, _} = Instance.set_readiness(inst, :bogus)
  end
end
