# mvm-elixir — secure microVMs on the BEAM, for the lexlean-r4 gpu clone

This directory adds Elixir microVMs to the cloned `gpu/` tree of
[Casey-allard/lexlean-r4](https://github.com/Casey-allard/lexlean-r4)
(main, `ed3ba33`). It is a port of
[Casey-allard/mvm](https://github.com/Casey-allard/mvm) (Apache-2.0),
the Rust workspace that runs untrusted workloads in microVMs — one
command from zero to secure sessions, locally and remotely. The port
keeps mvm's security shape (signed execution plans, hash-chained audit
log, command gate, default-deny egress with host-side secret
substitution, standby pool) and re-implements it as an OTP
application with zero Hex dependencies. Nothing in `gpu/` is modified;
this directory is additive only.

## What lives here

- `mix.exs` — the Mix project (`:mvm_ex`, Elixir ~> 1.17, no deps).
  `mix escript.build` produces `mvm_ex`; `mvmctl` is a wrapper that
  sets the locale and toolchain paths and runs it.
- `lib/mvm_ex/plan.ex` — execution plans. `synthesize/1` validates a
  plan (image, command, cpus 1–64, memory 64 MB–64 GB, timeout 1–3600 s,
  egress allowlist, secret placeholders) and digests the canonical JSON
  body with SHA-256. `sign/2` attaches an Ed25519 signature;
  `verify/2` recomputes the digest and checks the signature. Synthesis
  alone confers no authority, exactly as in mvm: signing and admission
  still gate execution.
- `lib/mvm_ex/audit.ex` — the hash-chained audit log. Every launch is
  recorded before the VM boots. Each entry carries the SHA-256 of the
  previous entry, so tampering with any earlier entry breaks every hash
  after it. `verify/1` recomputes the whole chain; `append_to_file/3`
  and `read_file/1` persist one canonical JSON object per line.
- `lib/mvm_ex/gate.ex` — the host-side command gate. Literal patterns
  match as substrings; patterns with `*` or `?` match as globs over the
  whole command. Decisions in precedence order: block beats
  require-approval beats allow (with logged matches reported). The
  default blocklist is ported verbatim from mvm's
  `default_blocklist()`: 13 entries covering destructive commands
  (`rm -rf /`, `mkfs`, `dd if=/dev/zero`, `> /dev/sda`, the fork bomb),
  privilege escalation (`nsenter` blocked, `unshare`/`chroot`
  approval-gated), sensitive files (`/etc/shadow`, `.ssh/id_rsa`,
  `.aws/credentials`), and VM escape vectors (`/dev/kvm`,
  `release_agent`).
- `lib/mvm_ex/instance.ex` — the instance lifecycle from
  `mvm_core::domain::instance`: statuses created, ready, running, warm,
  sleeping, stopped, destroyed, with the transition table enforced
  (illegal transitions are errors, covered by tests). Readiness
  (agent_connecting, services_starting, services_ready, degraded) rides
  alongside the lifecycle and never moves it on its own.
- `lib/mvm_ex/vm.ex` — one microVM session (GenServer). mvm boots a
  real hypervisor guest: Firecracker on Linux with `/dev/kvm`, HVF or
  libkrun on macOS. This VM has no `/dev/kvm`, so the backend here is
  `:software`, an isolated OS process in a per-instance jail — the same
  shape the owner ordered for this box (a software container CPU; a KVM
  guest is only an optional extra wrap on hosts that have one). The
  guest runs with a scrubbed environment (PATH only), the jail as its
  working directory, a wall-clock timeout, and read-only mounts as
  symlinks into the jail. Commands run through the BEAM spawn port
  (`/bin/sh -c 'exec ...'`), so they must be external binaries or an
  explicit `sh -c '...'` wrapper; shell builtins are not available bare.
- `lib/mvm_ex/pool.ex` — the standby pool. An unnamed run boots cold
  and leaves a standby VM of that image ready; the next matching run
  claims the standby instead of booting. Claims must land inside the
  300 ms warm-claim SLO or the standby is returned and the claim
  refused. Standbys are held within a host memory cap (default 4 GB)
  and reaped after the idle window (default 20 minutes).
- `lib/mvm_ex/egress.ex` — default-deny egress. A workload VM has no
  network device in mvm; everything the guest sends goes over vsock to
  a per-VM host process that opens the outbound connection itself. The
  host is the one place where the allowlist is enforced and where
  `${SECRET:NAME}` placeholders are swapped for real credentials, so
  the guest never holds them. `resolve/3` is the pure enforcement
  point; `fetch/3` performs the host-side request.
- `lib/mvm_ex/agent.ex` — the agent protocol (`AgentRequest` /
  `AgentResponse` from `mvm_core::domain::agent`) as JSON over the
  local node: node_info, node_stats, tenant_list, instance_list,
  wake_instance, instance_action, reconcile. Unsigned reconcile is
  accepted only in dev mode and rejected otherwise, matching the Rust
  `Reconcile` (unsigned, dev mode only) variant.
- `lib/mvm_ex/weights.ex` — inventory and verification for the sliced
  weight packs in `gpu/weights`. It reads the manifests and receipts
  that are actually in the clone and reports what is on disk, per pack,
  instead of assuming. `verify_pack/1` hashes every shard present
  against its manifest entry; `stitch_v8/2` reassembles the 360 v8
  parts and checks the container SHA-256.
- `lib/mvm_ex/web.ex` — a minimal `:gen_tcp` HTTP host for the
  in-browser page: `GET /` serves `web/index.html`,
  `GET /api/weights` returns the pack inventory,
  `POST /api/weights/verify` hash-verifies one pack,
  `POST /api/vm/run` gates a command, runs it in a microVM session
  with the selected pack mounted read-only, and returns the output,
  `GET /api/vm` reports the pool.
- `lib/mvm_ex/cli.ex` — the `mvmctl` escript: `doctor`, `weights`,
  `weights verify <pack>`, `weights stitch-v8 <out>`,
  `machine run --image <image> -- <command>`, `pool warm <n>`,
  `audit verify`.
- `web/index.html` — the browser page: the pack table with per-pack
  SHA-256 verification, and a run box that executes a command in a
  microVM session and shows the output. The integer inference engine
  that runs a pack in the browser is upstream `crates/wasm`, which is
  not part of this `gpu/` clone; the page says so.

## The weights in this clone

Read from the manifests and receipts on disk, not assumed:

| Pack | Source model | Size | Slices | On disk in main? |
| --- | --- | --- | --- | --- |
| v8 | UOR-R4 GLM v8 (`uor-r4-glm-v8-2b`, HF `caseyallard/uor-r4-store`) | 188,728,472 B | 360 × 512 KiB parts | yes, all 360 |
| v9 | UOR-R4 GLLM v9 (`UORGLLM9`) | 12,895,254 B | 25 × 512 KiB parts | yes, all 25 |
| v10 | UOR-R4 GLLM v10 (`UORR4V12`, 16L 256D) | 75,684,407 B | 73 × 1 MiB shards + 37 parity | yes, all 73 + 37 parity |
| v12_360m | SmolLM2-360M-Instruct (`HuggingFaceTB/SmolLM2-360M-Instruct`) | 196,669,221 B | 188 shards | yes, all 188 — in this beam repo (see top-level README for the size cut) |
| v13_qwen3_0_6b | Qwen3-0.6B (`Qwen/Qwen3-0.6B`) | 429,484,190 B | 410 pieces | manifests only — pieces on branch `weights-v13-qwen3-0.6b` |
| v13_qwen3_1_7b | Qwen3-1.7B (`Qwen/Qwen3-1.7B`) | 1,140,250,782 B | 1088 pieces | manifests only — pieces on branch `weights-v13-qwen3-1.7b` |

In this beam repo the v12 pieces ARE in `gpu/weights/v12_360m/`
(188/188 verified). The v13 pieces live on their own branches, with
root-level `weights/<pack>/` directories (not under `gpu/`); use
`scripts/fetch-weights.sh` in the repo root to fetch them on demand,
then point `MVM_GPU_ROOT` at a branch root to verify a pack there.
The tokenizer hash matches the hash stated in the upstream gpu README
(`d36d3e87…0f89`), and `gpu/short.uorlut` carries the `UORLUT01` magic.

## License note

The user called this "all MIT code". It is not quite that, and the
difference matters for reuse. Upstream lexlean-r4 carries both
`LICENSE-MIT` and `LICENSE-APACHE` at its root, and GitHub reports the
repo license as Apache-2.0. mvm is Apache-2.0. Both are permissive, so
cloning and porting are fine, but this port does not relicense anything:
the `gpu/` tree keeps its upstream licenses untouched, and this
directory's new files are also released under Apache-2.0 to match the
upstream they port.

## Running it

Prerequisites: Erlang/OTP 25 and Elixir 1.18.4. On this VM the
toolchain lives at `~/workspace/.tools/elixir-1.18.4/bin` with system
Erlang reinstalled from the Debian pool debs in
`~/workspace/.tools/erlang-debs/` (base, crypto, asn1, public-key, ssl,
runtime-tools, mnesia, xmerl, tftp, ftp, inets — the base package alone
does not ship `:inets`).

```sh
cd mvm-elixir
export PATH=$HOME/workspace/.tools/elixir-1.18.4/bin:$PATH
export ELIXIR_ERL_OPTIONS="+fnu" LC_ALL=C.UTF-8

mix test            # 45 tests, 0 failures on this VM
mix escript.build   # builds ./mvm_ex
./mvmctl doctor
./mvmctl weights
./mvmctl weights verify v9
./mvmctl machine run --image alpine -- printf hello-from-a-microvm

# Web page + API on :8931:
MVM_WEB_PORT=8931 mix run --no-halt
# then open http://localhost:8931/
```

`MVM_GPU_ROOT` overrides the gpu directory (default: `../gpu` next to
this project). `MVM_DATA_DIR` overrides the audit log and jail root
(default: a `mvm-ex` directory under the system temp dir).

## How a run flows

`machine run` synthesizes an execution plan, signs it with an
ephemeral Ed25519 key, verifies the signature, appends the plan to the
hash-chained audit log, boots a software-backend VM, gates the command,
runs it with a timeout, prints the output, and stops the VM. A blocked
command never reaches the guest: the gate answers first and the refusal
is itself audit-logged. The web route does the same through
`POST /api/vm/run`, returning 403 with the matched pattern and
category when the gate blocks.

## What is not ported

The full mvm workspace is 26 Rust crates and about 63 MB of source;
this port reproduces its operational core, not every line. The
hypervisor backends (Firecracker, HVF, libkrun), the Nix builder
pipeline, the OCI image fetcher, TPM attestation, snapshot encryption,
and the fleet controller are not ported. The software backend cannot
prevent a guest process from opening a socket directly the way a
hypervisor with no network device can; direct egress from a
software-backend guest is out of scope and is stated in STATUS.md
rather than hidden. The v10 XOR 2-of-3 parity set is inventoried but
its reconstruction is not verified. CUDA training (`gpu/*.cu`) is not
run here — this VM has no GPU and no CUDA toolchain. See STATUS.md for
the full verification scope.
