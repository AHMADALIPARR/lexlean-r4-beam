defmodule MvmEx.AgentTest do
  use ExUnit.Case, async: false
  alias MvmEx.Agent

  setup do
    {:ok, _} = Application.ensure_all_started(:mvm_ex)
    :ok
  end

  test "node_info reports the software backend and no kvm" do
    assert {:ok, %{"kind" => "node_info", "backend" => "software", "kvm_available" => false}} =
             Agent.handle(%{"kind" => "node_info"})
  end

  test "unsigned reconcile is rejected outside dev mode" do
    assert {:error, _} = Agent.handle(%{"kind" => "reconcile"})
    assert {:ok, %{"kind" => "reconcile_result"}} = Agent.handle(%{"kind" => "reconcile", "dev_mode" => true})
  end

  test "unknown kinds are errors" do
    assert {:error, _} = Agent.handle(%{"kind" => "explode"})
    assert {:error, _} = Agent.handle(%{})
  end

  test "wake on an empty pool reports failure instead of inventing a VM" do
    assert {:ok, %{"kind" => "wake_result", "success" => false}} =
             Agent.handle(%{"kind" => "wake_instance", "image" => "no-such-image"})
  end
end
