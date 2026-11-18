# lexlean-r4-beam — UOR-R4 weights and microVMs on the BEAM

This repository is the functioning cut of two upstream projects: the `gpu/`
tree of [Casey-allard/lexlean-r4](https://github.com/Casey-allard/lexlean-r4)
(main, `ed3ba33`) and the microVM runtime of
[Casey-allard/mvm](https://github.com/Casey-allard/mvm) (Apache-2.0),
re-implemented in Elixir/OTP as `mvm-elixir/`. It holds the weight packs
that verify on disk, the runtime that runs them in isolated sessions, the
guest tools those sessions use, and the training and corpus source that
produces the packs. It does not hold the parts that do not run, do not
verify, or do not fit on GitHub. The size rule decides the cut, and this
file states the rule, the cut, and the evidence for every claim in it.

## What this repository is

A geometric language model is a model that replaces dense floating-point
attention with integer geometry: Walsh-Hadamard butterflies, rational
causal attention, discrete lookup tables, and lattice readouts. The
upstream lexlean-r4 project builds such a model, called UOR-R4, in Lean,
Rust, CUDA, and WebAssembly, and serves it in a browser. The upstream
mvm project runs untrusted workloads in microVMs, with signed execution
plans, a hash-chained audit log, a command gate, a standby pool, and
default-deny egress. This repository joins the two at the point where
they actually meet: the weight packs live in `gpu/weights/`, the guest
tools live in `gpu/mvm_guest/`, and the Elixir runtime in `mvm-elixir/`
mounts a pack read-only into a microVM session, gates the command, runs
it, and returns the output. The web page at `mvm-elixir/web/index.html`
exposes that flow in a browser: a pack table with per-pack SHA-256
verification, and a run box that executes a command in a session and
shows the output.

The repository is 589 MB on disk, 890 files, with the largest single
file at 2.1 MB. That size is deliberate. GitHub blocks any single file
over 100 MiB in a normal push and warns above 50 MiB, recommends keeping
a repository under 1 GB in total, and strongly recommends staying under
5 GB. Every file in this repository is under 2.2 MB, so the per-file
rule never binds. The total is 589 MB, so the repository sits inside
the 1 GB recommendation with about 440 MB of headroom. The next pack
up, v13 Qwen3-0.6B at 429 MB, would push the total to about 1.02 GB,
just over the recommendation. The pack after that, v13 Qwen3-1.7B at
1.14 GB on its own, would push the total past 2 GB, past the per-push
limit as well as the recommendation. Size decides the cut, and the cut
is: v8, v9, v10, and v12 are in the repository, v13 is not. The v13
manifests and receipts are in the repository, so the packs are named,
sized, and sourced, and `scripts/fetch-weights.sh` fetches the pieces
on demand from their upstream branches and verifies them with the same
`mvmctl weights verify` command that verifies the packs in the repo.

## Provenance

Every file in this repository comes from one of two public upstreams,
or is new work written for this repository. Nothing here is
unattributed, and nothing here is claimed on trust. This section names
the sources, the audit, the defects found, and the exact commands
that reproduce every number in this file. `WATERMARK.md` carries the
per-file SHA-256 manifest for this tree.

### Sources

| Source | Exact reference | What was taken | License |
| --- | --- | --- | --- |
| Casey-allard/lexlean-r4 | main `ed3ba33`, `gpu/` only (sparse clone, 500 MB) | weights, manifests, receipts, tokenizer, `short.uorlut`, `rtx5090_glm_weights.bin`, `mvm_guest/` C sources, 9 CUDA trainers, 16 Rust files, `gpu/README.md` (verbatim in `docs/`) | MIT + Apache-2.0, both copied verbatim |
| Casey-allard/mvm | Apache-2.0, Rust workspace, 26 crates, ~63 MB | the domain model only: plans, audit, gate, lifecycle, pool, egress, agent, weights, web, re-implemented in Elixir, not copied | Apache-2.0; new files released under Apache-2.0 to match |
| HuggingFaceTB/SmolLM2-360M-Instruct | via branch `weights-v12-360m` | 188 data shards + parity + manifests + receipt | as upstream states |
| Qwen/Qwen3-0.6B, Qwen/Qwen3-1.7B | via branches `weights-v13-qwen3-0.6b`, `weights-v13-qwen3-1.7b` | manifests + receipts only; pieces fetched on demand | as upstream states |
| caseyallard/uor-r4-store | via the v8 manifest | 360 parts, stitched container | as upstream states |

Not audited here: the Lean model (slices R4-01 through R4-28), the
PrismPM template contract, `CONFORMANCE.md`, `prismpm.lock`, and the
`just vv` gate (needs the PrismPM SDK image, absent on the build VM);
the internals of the Rust mvm workspace beyond the ported domain
model; upstream `crates/wasm` (not in the `gpu/` clone).

### Audit: what was checked, and the result

| Check | Command | Result |
| --- | --- | --- |
| v8 shards + stitch | `./mvmctl weights verify v8` | 360/360 ok; container SHA-256 `34259da95f7760d0d8633ff53afd6d6cce9a89d98c3e5bd0b11ff862ceee5e48` matches manifest |
| v9 shards | `./mvmctl weights verify v9` | 25/25 ok |
| v10 shards | `./mvmctl weights verify v10` | 73/73 ok; 37 parity files present, reconstruction not verified |
| v12_360m shards | `./mvmctl weights verify v12_360m` | 188/188 ok |
| v13-0.6B shards | `./mvmctl weights verify v13_qwen3_0_6b` via staging gpu root | 410/410 ok, 2026-11-17, from branch clone (617 files) |
| v13-1.7B shards | `./mvmctl weights verify v13_qwen3_1_7b` | not verified yet; pieces still being recovered, count not stated until the command reports it |
| tokenizer | SHA-256 of `gpu/tokenizer.json` | `d36d3e8700a123e620012df77de195f244fbdb4d05d9e1aa7e77fa9407590f89`, matches the upstream gpu README claim |
| `short.uorlut` | magic bytes | `UORLUT01`, 2,156,480 B |
| `rtx5090_glm_weights.bin` | magic bytes | `UR4GLM06`, 800,436 B |
| runtime tests | `mix test` | 46 tests, 0 failures |
| doctor | `./mvmctl doctor` | all six packs listed with manifest state and shard counts |
| web flow | `:8931` smoke test | `/` 200, `/api/weights` live, benign run exit 0, `rm -rf /` 403, web verify v12 188/188 |
| Rust compile | `rustc --edition 2021 -O` per file | 7 of 10 binaries pass; 3 named failures (below) |
| licenses | SHA-256 of license files | LICENSE-MIT `b65b82603a4875244eaecc241d1666217ae7d9f8bf4ad3e7b1ac88d8888126ee`, LICENSE-APACHE `62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a`, verbatim from upstream root |

### Defects found: fixed, and not fixed

Fixed in this repository. No upstream source file was edited to make
anything pass; the fixes are in this repository's own code, scripts,
and docs.

- **v13 branch layout.** The first fetch script assumed v13 branches
  store pieces under `weights/<pack>/`, as the v12 branch does. They
  do not: v13 branches are flat at the branch root. The first count
  therefore read 0 for v13-0.6B even though the clone had finished.
  Fixed in commit `c809b1b`: the script clones without sparse
  checkout and verifies through a staging directory, and the README
  and STATUS.md state the flat layout.
- **v12 test count.** The ported test expected 0 v12 shards present,
  because v12 was not in the source clone. It is in this repository:
  188. Fixed: the count is 188, with a new v12 verify test (the 46th
  test).
- **Receipt paths and gpu root.** The ported `weights.ex` pointed at
  the old layout. Fixed: receipt paths now read `gpu/receipts/…`,
  and the `gpu_root` fallback reads `lexlean-r4-beam`.
- **License claim.** The order called the upstream code "all MIT".
  It is not: lexlean-r4 carries MIT and Apache-2.0, GitHub reports
  Apache-2.0, mvm is Apache-2.0. Fixed in the record: both licenses
  are copied verbatim, nothing is relicensed, and no license bearing
  the owner's name was touched.
- **Layout moves.** Receipts moved to `gpu/receipts/`, CUDA to
  `gpu/cuda/`, Rust to `gpu/rust/`, the upstream gpu README kept
  verbatim at `docs/upstream-gpu-README.md`.

Found and not fixed, named here so nobody has to discover them:

- `recompile_holo_v13` does not compile standalone: it needs the
  external `sha2` crate, which a bare `rustc` invocation does not
  link.
- `train_native_q31_r4` and `train_uorlut_v8` do not compile
  standalone: they need `../crates/wasm/src/lexlean_generated.rs`,
  from upstream `crates/wasm`, which is not in the `gpu/` clone.
- v10 XOR 2-of-3 parity reconstruction is not verified; parity files
  are inventoried as present. v12 parity is likewise inventoried,
  not reconstruction-verified.
- The nine CUDA trainers were not compiled or run: no GPU and no
  CUDA toolchain on the build VM. Training times and costs in the
  receipts are upstream's claims, repeated only as receipt contents.
- The hypervisor backends (Firecracker/HVF/libkrun) are not ported.
  The backend here is `:software`; it cannot prevent a guest process
  from opening a socket directly the way a hypervisor with no network
  device can.
- `Egress.fetch/3` uses TLS with verification disabled; integrity
  for fetched weight material comes from manifest SHA-256, not from
  TLS.
- Rust `glob_match` semantics are not independently verified against
  the ported gate.
- The browser integer-inference engine (`crates/wasm`) is not in
  this repository, so no in-browser inference run was performed.

### Owner-reported Jetson validation (not run on the build VM)

On 2026-11-17 the owner validated the V13 Qwen3-0.6B-derived pack on
his Jetson, in `snap-os/jetson` (student/conversion/,
evidence/lexlean-conversion/final-tests.log,
LEXLEAN-WEIGHT-REUSE-AUDIT.md; 23 files). The lossless integer
conversion preserved 911,616 tested logits, KV state, and generated
IDs exactly; both versions returned "Hello!" in the chat smoke test;
transformer primitives passed 29,824 Jetson CUDA comparisons,
including checks against his P4 kernels; seven converter tests
passed. The FP32 export passed numerical checks but changed observed
behavior, so it remains experimental and the lossless integer path is
the validated target. Those numbers are the owner's, from his
hardware, not from this VM; the conversion files live in his snap-os
tree, not in this repository.

### How to reproduce every number above

Prerequisites: Erlang/OTP 25 and Elixir 1.18.4, `rustc`, `git`. The
`mvmctl` wrapper sets the locale and toolchain paths, so the commands
work from `mvm-elixir/` without hand-setting the environment.

```sh
git clone https://github.com/AHMADALIPARR/lexlean-r4-beam.git
cd lexlean-r4-beam/mvm-elixir
mix test                              # expect: 46 tests, 0 failures
mix escript.build                     # builds ./mvm_ex
./mvmctl doctor                       # expect: all six packs listed
./mvmctl weights verify v8            # expect: 360/360 shards ok
./mvmctl weights verify v9            # expect: 25/25 shards ok
./mvmctl weights verify v10           # expect: 73/73 shards ok
./mvmctl weights verify v12_360m      # expect: 188/188 shards ok
sha256sum ../gpu/tokenizer.json        # expect: d36d3e87…0f89 (full hash in the table above)
```

For v13-0.6B, `scripts/fetch-weights.sh` clones the branch, verifies
through a staging directory, and reports the count; expect 410/410.
For the Rust check, `rustc --edition 2021 -O` each file in
`gpu/rust/`; expect 7 of 10 binaries to pass and the three named
failures to fail for the named reasons. For the web flow,
`MVM_WEB_PORT=8931 mix run --no-halt`, then `GET /` (200),
`GET /api/weights` (live inventory), and a benign
`POST /api/vm/run` (output, exit 0) against a blocked `rm -rf /`
(403).

The checks are deterministic where they are hash checks: SHA-256
against a manifest gives the same answer on every machine. The
wall-clock figures are thresholds, not values: a warm claim must land
inside the 300 ms SLO, and the standby pool reaps after the
20-minute idle window. The v13 fetch depends on the upstream branches
still existing at the named references; if a branch moves, the fetch
fails loudly instead of silently verifying the wrong pieces.

## Layout

```
lexlean-r4-beam/
  README.md                  this file
  STATUS.md                  verification scope, dates, and limits
  LICENSE-MIT                upstream lexlean-r4 MIT license, verbatim
  LICENSE-APACHE             upstream lexlean-r4 Apache-2.0 license, verbatim
  WATERMARK.md               per-file SHA-256 manifest for this tree
  .gitignore                 build outputs and the escript binary
  mvm-elixir/                the BEAM microVM runtime (see below)
    mix.exs                  Mix project, zero Hex dependencies
    mvmctl                   wrapper script for the mvm_ex escript
    lib/mvm_ex/              plan, audit, gate, instance, vm, pool,
                             egress, agent, weights, web, cli, json
    test/                    46 ExUnit tests
    web/index.html           pack table, verify buttons, run box
  gpu/
    tokenizer.json           ByteBPE-4096 tokenizer, hash in STATUS.md
    short.uorlut             UORLUT01 container, 2,156,480 bytes
    rtx5090_glm_weights.bin  UR4GLM06 tensor, 800,436 bytes
    served-s1.header.json    header manifest for the served stack
    weights/
      manifest.json          v8 container manifest
      uor_r4_glm_v8.uorlut.part000..359   v8, 360 parts
      v9/                    25 parts + manifest
      v10/                   73 shards + 37 parity + manifests
      v12_360m/              188 shards + parity + manifests + receipt
      v13_qwen3_0_6b/        manifests only, pieces on branch
      v13_qwen3_1_7b/        manifests only, pieces on branch
      mvm-pkgs/              10 built RV64 guest ELFs + index.json
    mvm_guest/               C guest sources (agent, box, packages, vsock)
    cuda/                    CUDA trainers, source only (see below)
    rust/                    Rust corpus and trainer source (see below)
    receipts/                RTX 4090 / RTX 5090 training receipts
  scripts/
    fetch-weights.sh         fetch v13 pieces on demand, then verify
  docs/
    upstream-gpu-README.md   upstream gpu/README.md, verbatim, for reference
```

The layout is flat on purpose. The runtime is one directory, the data
is one directory, the source that produces the data is two directories,
and the evidence is one directory. Nothing in this repository is a
submodule, a vendored copy of a second runtime, or a duplicate of the
same weight pack in two places. The LexLean Lean model, the PrismPM
template contract, the Rust mvm workspace, and the browser WASM engine
are not in this repository, and the section below on what is not here
says why, in each case, with the upstream location where the piece
lives.

## The weight packs

The packs are the reason the repository exists, and every pack in it
is verified by hash against its own manifest, not by trust in a file
name. The table below is read from the manifests and receipts on disk.

| Pack | Source model | Size | Slices | In this repo |
| --- | --- | --- | --- | --- |
| v8 | UOR-R4 GLM v8, HF `caseyallard/uor-r4-store` | 188,728,472 B | 360 x 512 KiB parts | yes, all 360 |
| v9 | UOR-R4 GLLM v9, `UORGLLM9` | 12,895,254 B | 25 x 512 KiB parts | yes, all 25 |
| v10 | UOR-R4 GLLM v10, `UORR4V12`, 16L 256D | 75,684,407 B | 73 x 1 MiB shards + 37 parity | yes, all 73 + 37 parity |
| v12_360m | SmolLM2-360M-Instruct, HF `HuggingFaceTB/SmolLM2-360M-Instruct` | 196,669,221 B | 188 x 1 MiB shards | yes, all 188 |
| v13_qwen3_0_6b | Qwen3-0.6B, `Qwen/Qwen3-0.6B` | 429,484,190 B | 410 pieces | manifests only |
| v13_qwen3_1_7b | Qwen3-1.7B, `Qwen/Qwen3-1.7B` | 1,140,250,782 B | 1,088 pieces | manifests only |

Verification is a command, not a claim. From `mvm-elixir/`:

```sh
./mvmctl weights verify v8        # 360/360 shards ok
./mvmctl weights verify v9        # 25/25 shards ok
./mvmctl weights verify v10       # 73/73 shards ok
./mvmctl weights verify v12_360m  # 188/188 shards ok
```

The v8 check also stitches the 360 parts and compares the container
SHA-256 `34259da95f7760d0d8633ff53afd6d6cce9a89d98c3e5bd0b11ff862ceee5e48`
against the manifest, and it matches exactly. The v10 parity set is
inventoried as present, 37 files, and its stitch manifest describes
an XOR 2-of-3 scheme, 73 data shards plus 37 parity shards in 37
groups. Parity reconstruction is not verified in this repository, and
STATUS.md says so plainly. The v12 directory holds 285 files in total:
188 data shards, 97 parity files, and the manifest, stitch manifest,
and receipt. The tokenizer hash matches the hash stated in the
upstream gpu README, `d36d3e8700a123e620012df77de195f244fbdb4d05d9e1aa7e77fa9407590f89`,
and `short.uorlut` carries the `UORLUT01` magic in its first eight
bytes. The `rtx5090_glm_weights.bin` file carries the `UR4GLM06`
magic and holds the trained tensor for the general GLM, 205 basins,
9,393 vocabulary stems, 1,742 token horizons, and 3,484 transitions,
as its receipt describes.

The v13 packs deserve a precise statement, because their absence is
a decision and not an oversight. Their manifests and stitch manifests
are in `gpu/weights/v13_qwen3_0_6b/` and `gpu/weights/v13_qwen3_1_7b/`,
and their receipts are in `gpu/receipts/`, so the repository names
the source models, the sizes, the piece counts, and the upstream
branches. The pieces themselves live on the upstream branches
`weights-v13-qwen3-0.6b` and `weights-v13-qwen3-1.7b`, flat at the
branch root — `manifest.json`, `piece_*.bin`, and `parity_*.bin` at
the top level, not under `weights/<pack>/` and not under `gpu/`.
(The v12 branch differs: its pieces are under
`weights/v12_360m/`.) `scripts/fetch-weights.sh` clones a branch
without sparse checkout and verifies through a staging directory
with symlinks, because `mvmctl` expects `weights/<pack>/` under
the gpu root. The v13-0.6B pieces were verified after this
repository was cut, on 2026-11-17, at 410/410 shards ok against
their manifest, from the branch clone at
`~/workspace/lexlean-r4-weights-v13-qwen3-0.6b` (617 files on disk).
The v13-1.7B pieces were still being recovered at that time; see
STATUS.md for their state.

## The runtime: mvm-elixir

`mvm-elixir/` is an Elixir/OTP port of the mvm Rust workspace. The
upstream workspace is 26 crates and about 63 MB of source. This port
reproduces its operational core, not every line, and it does so with
zero Hex dependencies: the Mix project is `:mvm_ex`, Elixir ~> 1.17,
and the only libraries are the ones Erlang/OTP ships. The port keeps
mvm's security shape, and the module list below follows the upstream
domain model, file by file.

```
browser / curl
      |
      v
  web.ex  (:gen_tcp HTTP, :8931)
      |
      +-- weights.ex  (inventory + SHA-256 verify + v8 stitch)
      +-- cli.ex      (mvmctl escript: doctor, weights, machine, pool, audit)
      |
      v
  plan.ex  (synthesize -> digest -> sign Ed25519 -> verify)
      |
      v
  audit.ex (hash-chained JSONL, append before boot, verify whole chain)
      |
      v
  gate.ex  (13-entry default blocklist, verbatim from mvm)
      |
      v
  instance.ex + pool.ex  (lifecycle, readiness, 300 ms warm-claim SLO)
      |
      v
  vm.ex  (one session, software backend on this host)
      |
      +-- egress.ex  (default-deny, host-side fetch, ${SECRET:NAME})
      +-- agent.ex   (AgentRequest / AgentResponse protocol)
```

A run flows in one order, and the order is the security property.
`machine run` synthesizes an execution plan, validates the image,
command, CPU count, memory, timeout, egress allowlist, and secret
placeholders, digests the canonical JSON body with SHA-256, signs it
with an ephemeral Ed25519 key, and verifies the signature. Synthesis
alone confers no authority, exactly as in mvm: signing and admission
still gate execution. The plan is appended to the hash-chained audit
log before the VM boots, so a launch that never boots is still
recorded, and a launch that boots is recorded before it can do
anything. Each audit entry carries the SHA-256 of the previous entry,
so tampering with any earlier entry breaks every hash after it, and
`audit verify` recomputes the whole chain. The command gate answers
next: literal patterns match as substrings, patterns with `*` or `?`
match as globs over the whole command, and decisions run in precedence
order, block beats require-approval beats allow, with logged matches
reported. The default blocklist is ported verbatim from mvm's
`default_blocklist()`: 13 entries covering destructive commands
(`rm -rf /`, `mkfs`, `dd if=/dev/zero`, `> /dev/sda`, the fork bomb),
privilege escalation (`nsenter` blocked, `unshare` and `chroot`
approval-gated), sensitive files (`/etc/shadow`, `.ssh/id_rsa`,
`.aws/credentials`), and VM escape vectors (`/dev/kvm`,
`release_agent`). A blocked command never reaches the guest, and the
refusal is itself audit-logged. The instance lifecycle follows
`mvm_core::domain::instance`: created, ready, running, warm, sleeping,
stopped, destroyed, with the transition table enforced and illegal
transitions rejected as errors. Readiness, agent_connecting,
services_starting, services_ready, degraded, rides alongside the
lifecycle and never moves it on its own. The standby pool holds warm
instances within a host memory cap, default 4 GB, reaps them after the
idle window, default 20 minutes, and a warm claim must land inside
the 300 ms SLO or the standby is returned and the claim is refused.

The backend is the honest limit of this port, and it is stated here
rather than hidden. Upstream mvm boots a real hypervisor guest:
Firecracker on Linux with `/dev/kvm`, HVF or libkrun on macOS. This
repository was built on a VM with no `/dev/kvm`, so the backend here
is `:software`, an isolated OS process in a per-instance jail, with a
scrubbed environment, the jail as its working directory, a wall-clock
timeout, and read-only mounts as symlinks into the jail. Commands run
through the BEAM spawn port, `/bin/sh -c 'exec ...'`, so they must be
external binaries or an explicit `sh -c '...'` wrapper; shell builtins
are not available bare. A software backend cannot prevent a guest
process from opening a socket directly the way a hypervisor with no
network device can, so direct egress from a software-backend guest is
out of scope. Brokered egress, `MvmEx.Egress`, is enforced host-side:
a workload VM has no network device in mvm, everything the guest
sends goes over vsock to a per-VM host process that opens the outbound
connection itself, the host is the one place where the allowlist is
enforced, and `${SECRET:NAME}` placeholders are swapped for real
credentials on the host, so the guest never holds them. `Egress.fetch/3`
uses TLS with verification disabled, and integrity for fetched weight
material comes from the manifest SHA-256 checks, not from TLS. That
is a documented limit, not a recommendation.

The agent protocol, `MvmEx.Agent`, carries `AgentRequest` and
`AgentResponse` as JSON over the local node: node_info, node_stats,
tenant_list, instance_list, wake_instance, instance_action, and
reconcile. Unsigned reconcile is accepted only in dev mode and
rejected otherwise, matching the Rust `Reconcile` variant. The web
host, `MvmEx.Web`, is a minimal `:gen_tcp` HTTP server: `GET /`
serves the page, `GET /api/weights` returns the live pack inventory,
`POST /api/weights/verify` hash-verifies one pack, `POST /api/vm/run`
gates a command, runs it in a session with the selected pack mounted
read-only, and returns the output, and `GET /api/vm` reports the
pool. The page itself is `web/index.html`: a pack table with per-pack
verification, and a run box that executes a command in a session and
shows the output.

## Running it

Prerequisites are Erlang/OTP 25 and Elixir 1.18.4. On the build VM
the toolchain lives at `~/workspace/.tools/elixir-1.18.4/bin`, with
system Erlang reinstalled from Debian pool debs in
`~/workspace/.tools/erlang-debs/`, base plus crypto, asn1, public-key,
ssl, runtime-tools, mnesia, xmerl, tftp, ftp, and inets, because the
base package alone does not ship `:inets`, which this application
needs. The `mvmctl` wrapper sets the locale and toolchain paths, so
the commands below work from the `mvm-elixir/` directory without
hand-setting the environment each time.

```sh
cd mvm-elixir
mix test            # 46 tests, 0 failures on the build VM
mix escript.build   # builds ./mvm_ex
./mvmctl doctor
./mvmctl weights
./mvmctl weights verify v12_360m
./mvmctl machine run --image alpine -- printf hello-from-a-microvm

# Web page + API on :8931:
MVM_WEB_PORT=8931 mix run --no-halt
# then open http://localhost:8931/
```

`MVM_GPU_ROOT` overrides the gpu directory, defaulting to `../gpu`
next to the project, and `MVM_DATA_DIR` overrides the audit log and
jail root, defaulting to a `mvm-ex` directory under the system temp
dir. The doctor command prints the backend, the `/dev/kvm` state,
the OTP and Elixir versions, the gpu root, and every pack with its
manifest state and shard count, so a new machine can be checked in
one command before anything is run.

## The guest: mvm_guest and mvm-pkgs

The guest is the other half of the microVM story, and it lives in
`gpu/mvm_guest/` and `gpu/weights/mvm-pkgs/`. The C sources build ten
static freestanding `RV64IMAC` ELF64 binaries, `EM_RISCV = 243`,
with `build_pkgs.rs` in the same directory: `jq`, `rg`, `tree`,
`xxd`, `sha256sum`, `bc`, `wc`, `head`, `tail`, and `http`, plus the
agent (`mvm_agent.c`), the box (`mvmbox.c`), and the vsock probe
(`vsock_probe.c`). The built binaries are already in
`gpu/weights/mvm-pkgs/` with their `index.json` catalog, so a session
can use them without rebuilding. The package sources are small, single
purpose tools, each one a few hundred lines, and they are the tools a
guest session is expected to have: search, inspect, hash, and fetch,
nothing more. The vsock probe is the link between the guest and the
host-side egress process, and it is the reason the guest tools do not
need their own network stack. The guest sources are copied verbatim
from upstream, and the built ELFs are copied verbatim from the
upstream clone, with their catalog hash intact.

## The source: cuda and rust

The `gpu/cuda/` and `gpu/rust/` directories hold the source that
produces the packs, split by language so a reader can find a trainer
without wading through corpus builders. The CUDA directory holds nine
files: `train_gllm_v9.cu`, `train_gllm_v10.cu`, `train_v11_gpu.cu`,
`general_glm.cu`, `cuda_stack.cu`, `discrete.cu`, and the three
`spiralcore_fbs*.cu` files. These are pure CUDA trainers for the
Ada RTX 4090 and Blackwell RTX 5090, `compute_75` through `compute_89`
and `compute_120`, and they were not compiled or run on the build VM,
which has no GPU and no CUDA toolchain. Their claims, the receipts in
`gpu/receipts/`, the training times, and the costs, are upstream's,
repeated here only as receipt contents. On a Jetson or an RTX host
they are the training path, and on this host they are source only,
which is why they sit in their own directory instead of beside the
runtime.

The Rust directory holds sixteen files, and unlike the CUDA files
they were compile-checked on the build VM with `rustc` from
`~/workspace/.tools/cargo/bin/`, edition 2021, optimisation on. Seven
of the ten binaries compile cleanly: `build_v9_corpus`,
`build_v10_corpus`, `build_v11_corpus`, `fetch_hf_datasets`,
`recompile_r4_teacher`, `train_general_glm`, and `train_v11`. The
corpus builders are the offline dataset path: `build_v9_corpus`
builds the v9 compositional corpus, `build_v10_corpus` builds the
100,000-sequence v10 multi-turn corpus with its held-out validation
split, `build_v11_corpus` builds the v11 corpus, and
`fetch_hf_datasets` streams and curates HuggingFace turns into a TSV
corpus for the v8 trainer. The three files that do not compile
standalone fail for named reasons, and the reasons are recorded in
STATUS.md rather than fixed by editing upstream code. `recompile_holo_v13`
needs the external `sha2` crate, which a single-file `rustc`
invocation does not link. `train_native_q31_r4` and `train_uorlut_v8`
need `../crates/wasm/src/lexlean_generated.rs`, a file from the
upstream `crates/wasm` tree, which is not in the `gpu/` clone at all.
Three further files, `glm_reasoner_template`, `v10_corpus_ab`, and
`v10_corpus_cde`, are modules, not programs, and they fail only when
compiled alone, with missing-type and missing-import errors that
disappear when their parent binaries compile: `build_v10_corpus`
includes the v10 corpus modules, and `train_general_glm` includes the
reasoner template. No Rust file in this repository was edited to make
it compile. The compile check is a report, not a repair.

## What is not here

The cut is as much a part of this repository as the contents, so the
exclusions are listed here with their reasons. The LexLean Lean model,
the twenty-eight source slices R4-01 through R4-28, the PrismPM
template contract, `CONFORMANCE.md`, `prismpm.lock`, and the `just vv`
acceptance gate are not here. That tree is the upstream proof and
model layer, it is not the functioning runtime, and its gate needs the
PrismPM SDK image, which is not on the build VM. The Rust mvm
workspace, 26 crates and about 63 MB of source, is not here either,
because the Elixir port replaces it, and shipping both would be two
runtimes for one job. The browser integer-inference engine, upstream
`crates/wasm`, is not here, because it is not in the `gpu/` clone,
and that is the one honest gap in the original order: the page in
this repository serves weight metadata and runs host-side microVM
sessions, it does not execute a model in the browser. Fetching
`crates/wasm` separately is the next step if in-browser inference is
wanted, and it is a separate fetch because it is a separate upstream
tree with its own build. The v13 weight pieces are not here, for the
size reason stated at the top. The `.git` history of the upstream
clone, 192 MB on its own, is not here, because this repository starts
fresh with its own history and its own watermark.

## Licenses

The user who ordered this work called the upstream code "all MIT".
It is not all MIT, and the difference matters for reuse. Upstream
lexlean-r4 carries both `LICENSE-MIT` and `LICENSE-APACHE` at its
root, and GitHub reports the repository license as Apache-2.0. The
mvm project is Apache-2.0. Both licenses are permissive, so cloning
and porting are fine, and nothing in this repository is relicensed:
the upstream licenses are copied verbatim as `LICENSE-MIT` and
`LICENSE-APACHE`, the `gpu/` tree keeps its upstream license
statements untouched, and the new files in `mvm-elixir/` are released
under Apache-2.0 to match the upstream they port. No license bearing
the owner's name was touched, added, or removed in this repository.

## Verification

`STATUS.md` holds the full verification record: the dates, the host,
the commands, the counts, and the limits. The short form is that on
the build VM, `mix test` runs 46 tests with 0 failures, `mvmctl
doctor` lists all six packs, `weights verify` passes 360/360 for v8,
25/25 for v9, 73/73 for v10, and 188/188 for v12_360m, the web flow
returns 200 on `/`, live inventory on `/api/weights`, output with
exit 0 on a benign run, 403 with the matched pattern and category on
`rm -rf /`, and 188/188 on a web verify of v12. The Rust compile
check passes 7 of 10 binaries, with the three failures named and
explained. The CUDA trainers are not compiled or run here. The v10
parity reconstruction is not verified. The hypervisor backends are
not ported. The browser inference engine is not in this repository.
Nothing in this file claims otherwise, and anything that changes
those facts belongs in STATUS.md first, with a date and a command,
before it belongs in this README.
