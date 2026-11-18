defmodule MvmEx.GateTest do
  use ExUnit.Case, async: true
  alias MvmEx.Gate

  test "default blocklist blocks destructive and escape commands" do
    gate = Gate.new()
    assert {:blocked, "rm -rf /", "destructive"} = Gate.evaluate(gate, "rm -rf / tmp")
    assert {:blocked, "mkfs", "destructive"} = Gate.evaluate(gate, "mkfs.ext4 /dev/sda1")
    assert {:blocked, "/etc/shadow", "sensitive_file"} = Gate.evaluate(gate, "cat /etc/shadow")
    assert {:blocked, "/dev/kvm", "vm_escape"} = Gate.evaluate(gate, "ls /dev/kvm")
    assert {:blocked, ".ssh/id_rsa", "sensitive_file"} = Gate.evaluate(gate, "cat ~/.ssh/id_rsa")
  end

  test "block beats require-approval; approval beats allow" do
    gate = Gate.new()
    assert {:blocked, _, _} = Gate.evaluate(gate, "unshare --mount; rm -rf /")
    assert {:requires_approval, "unshare", "privilege_escalation"} = Gate.evaluate(gate, "unshare --user sh")
    assert {:requires_approval, "chroot", "privilege_escalation"} = Gate.evaluate(gate, "chroot /jail sh")
  end

  test "benign commands are allowed" do
    gate = Gate.new()
    assert {:allow, []} = Gate.evaluate(gate, "uname -s")
    assert {:allow, []} = Gate.evaluate(gate, "ls -la; sha256sum pack.part000")
    assert {:allow, []} = Gate.evaluate(gate, "printf hello")
  end

  test "dev mode auto-approves approval-gated commands but never blocks" do
    gate = Gate.new()
    assert {:allow, _} = Gate.evaluate_dev_mode(gate, "unshare --user sh")
    assert {:blocked, _, _} = Gate.evaluate_dev_mode(gate, "rm -rf /")
  end

  test "glob patterns match the whole command" do
    gate = [%{pattern: "curl *evil.example", category: "egress", severity: :high, action: :block}]
    assert {:blocked, _, _} = Gate.evaluate(gate, "curl https://evil.example")
    assert {:allow, []} = Gate.evaluate(gate, "curl https://good.example/x")
    assert {:allow, []} = Gate.evaluate(gate, "curl https://evil.example/x/extra")
    assert Gate.glob_match?("a?c", "abc")
    refute Gate.glob_match?("a?c", "ac")
    assert Gate.glob_match?("*.bin", "shard_000.bin")
  end
end
