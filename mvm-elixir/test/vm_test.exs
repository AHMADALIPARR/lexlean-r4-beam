defmodule MvmEx.VMTest do
  use ExUnit.Case, async: true
  alias MvmEx.{Instance, VM}

  defp start_vm do
    id = "vm-test-#{:erlang.unique_integer([:positive])}"
    {:ok, instance} = Instance.new(%{"id" => id, "image" => "alpine"})
    {:ok, pid} = VM.start_link(instance, data_dir: Path.join(System.tmp_dir!(), "mvm-ex-test"))
    {id, pid}
  end

  test "exec runs a benign command and returns output + exit status" do
    {_id, pid} = start_vm()
    assert {:ok, %{output: output, exit_status: 0}} = VM.exec(pid, "printf hello-vm")
    assert output == "hello-vm"
    assert VM.status(pid)["status"] == "running"
    assert :ok = VM.stop(pid)
  end

  test "exec of a failing command returns its exit status, not an error" do
    # `false` is an external binary: spawn ports run via `sh -c 'exec ...'`,
    # so shell builtins such as `exit` are not available as commands.
    {_id, pid} = start_vm()
    assert {:ok, %{exit_status: 1}} = VM.exec(pid, "false")
    VM.stop(pid)
  end

  test "gate blocks destructive commands before anything runs" do
    {_id, pid} = start_vm()
    assert {:error, {:blocked, "rm -rf /", "destructive"}} = VM.exec(pid, "rm -rf / tmp")
    assert {:error, {:blocked, "/etc/shadow", "sensitive_file"}} = VM.exec(pid, "cat /etc/shadow")
    VM.stop(pid)
  end

  test "gate holds approval-gated commands for approval" do
    {_id, pid} = start_vm()
    assert {:error, {:requires_approval, "unshare", "privilege_escalation"}} = VM.exec(pid, "unshare --user sh")
    VM.stop(pid)
  end

  test "exec times out and the VM stays usable" do
    {_id, pid} = start_vm()
    assert {:error, :timeout} = VM.exec(pid, "sleep 30", 200)
    assert {:ok, %{output: "after", exit_status: 0}} = VM.exec(pid, "printf after")
    VM.stop(pid)
  end

  test "read-only mount lets the guest read a pack but the jail is the cwd" do
    id = "vm-mount-#{:erlang.unique_integer([:positive])}"
    {:ok, instance} = Instance.new(%{"id" => id, "image" => "alpine"})
    host_file = Path.join(System.tmp_dir!(), "mvm-ex-mount-#{id}.txt")
    File.write!(host_file, "pack-bytes")
    {:ok, pid} = VM.start_link(instance, data_dir: Path.join(System.tmp_dir!(), "mvm-ex-test"), mounts: [{host_file, "pack.txt"}])
    assert {:ok, %{output: "pack-bytes", exit_status: 0}} = VM.exec(pid, "cat pack.txt")
    VM.stop(pid)
    File.rm(host_file)
  end
end
