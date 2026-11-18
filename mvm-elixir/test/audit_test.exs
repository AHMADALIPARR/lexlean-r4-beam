defmodule MvmEx.AuditTest do
  use ExUnit.Case, async: true
  alias MvmEx.Audit

  test "chain verifies and tampering is detected" do
    {:ok, entries} =
      Audit.build([
        %{event: "plan_signed", data: %{"plan" => "p1"}},
        %{event: "vm_created", data: %{"instance" => "i1"}},
        %{event: "exec_finished", data: %{"exit_status" => 0}}
      ])

    assert length(entries) == 3
    assert :ok = Audit.verify(entries)
    assert hd(entries).prev == Audit.genesis()

    [first | rest] = entries
    tampered = [%{first | data: %{"plan" => "p2"}} | rest]
    assert {:error, _} = Audit.verify(tampered)

    dropped = tl(entries)
    assert {:error, _} = Audit.verify(dropped)
  end

  test "append to file then read and verify" do
    path = Path.join(System.tmp_dir!(), "mvm-ex-audit-test-#{:erlang.unique_integer([:positive])}.log")
    assert {:ok, _} = Audit.append_to_file(path, "plan_signed", %{"plan" => "p1"})
    assert {:ok, _} = Audit.append_to_file(path, "vm_created", %{"instance" => "i1"})
    assert {:ok, entries} = Audit.read_file(path)
    assert length(entries) == 2
    assert :ok = Audit.verify(entries)
    File.rm(path)
  end

  test "missing file reads as empty" do
    assert {:ok, []} = Audit.read_file("/nonexistent/mvm-ex-audit.log")
  end
end
