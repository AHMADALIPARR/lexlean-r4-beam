defmodule MvmEx do
  @moduledoc """
  Elixir port of Casey-allard/mvm (Apache-2.0) — secure microVMs, one
  command from zero to secure sessions — running on the BEAM.

  What is ported, and what is not:

  - Ported: execution plans (synthesize/sign/verify, Ed25519),
    hash-chained audit log, command gate with the verbatim default
    blocklist, instance lifecycle + readiness, standby pool with the
    300 ms warm-claim SLO and memory cap, default-deny egress with
    host-side secret substitution, weight-pack inventory + SHA-256
    verification for the sliced packs in `gpu/weights`, a minimal
    HTTP host for the in-browser page, and the `mvmctl` escript.
  - Not ported: the hypervisor backends. Firecracker (/dev/kvm),
    HVF and libkrun do not exist on this VM, so the backend here is
    `:software` — an isolated OS process in a per-instance jail.
    The agent protocol types (AgentRequest/AgentResponse) are modeled
    as plain maps in `MvmEx.Agent`; the full Rust workspace
    (26 crates, ~63 MB of source) is not line-for-line reproduced,
    and this file says so instead of implying otherwise.
  """

  @spec backend() :: :software
  def backend, do: :software

  @spec kvm_available?() :: boolean()
  def kvm_available?, do: File.exists?("/dev/kvm")
end
