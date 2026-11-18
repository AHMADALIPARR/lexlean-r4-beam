# STATUS — mvm-elixir (Elixir port of mvm into the lexlean-r4 gpu clone)

> NOTE (beam repo): this file is the port record as written in the
> source clone. In this repo v12 pieces ARE on disk and verified
> 188/188 (see the top-level STATUS.md and the updated weights test);
> v13 pieces are still manifests only. The top-level STATUS.md
> supersedes this file for v12.

Date: 2026-11-17. All checks below ran on this VM unless stated otherwise.

## Upstream state (verified)

- Clone: `~/workspace/lexlean-r4-gpu`, sparse checkout of `gpu/` only,
  main branch HEAD `ed3ba33` ("Engine tick 273: 1 proved (R4-F276)..."),
  500 MB on disk (308 MB `gpu/`, 192 MB `.git`). Tree is otherwise clean;
  the only addition is `mvm-elixir/`.
- No upstream file was modified. `gpu/`, `AGENTS.md` and every upstream
  file are byte-identical to the checkout.
- Licenses: upstream lexlean-r4 root carries `LICENSE-MIT` and
  `LICENSE-APACHE`; GitHub reports Apache-2.0. mvm is Apache-2.0. The
  user said "all MIT code" — that is not exact; both are permissive, so
  cloning/porting is fine, and nothing was relicensed.
- Upstream `AGENTS.md` (template-contract/1) was read. This addition
  respects it: no upstream file edited, no stubs (R4), zero Hex deps so
  no wildcard/path/Git/dev-only substitute (R6). The upstream `just vv`
  acceptance gate was NOT run here — it needs the PrismPM SDK image
  from `prismpm.lock`, which is not on this VM. This directory's gate
  is `mix test` plus the weight verification below.

## Verification performed on this VM

- `mix test`: 45 tests, 0 failures (9.1 s). Covers: JSON canonical
  encode/decode round-trip, plan synthesize/sign/verify + tamper
  rejection + digest-mismatch rejection, audit chain build/verify +
  tamper/drop detection + file append/read, command gate (all 13
  default-blocklist entries, precedence, dev mode, globs), instance
  lifecycle transitions + illegal-transition rejection, egress
  default-deny + secret substitution + unknown-secret error, VM exec
  (output/exit status, gate block, approval hold, timeout + reuse,
  read-only mount), pool warm/claim inside the 300 ms SLO + memory cap
  + idle reap, agent protocol (node_info, unsigned-reconcile rejection,
  unknown kinds, wake on empty pool), weights (see below).
- Weights, all read from the on-disk manifests/receipts:
  - v9: 25/25 shards hash-verified against `manifest.json`.
  - v10: 73/73 data shards hash-verified; 37 parity files present;
    stitch manifest is XOR 2-of-3, 73 data + 37 parity, 37 groups.
  - v8: stitched from 360 parts; 188,728,472 bytes and container
    SHA-256 `34259da9…ee5e48` match the manifest exactly.
  - v12/v13: manifests + receipts present on main; 0 pieces on disk.
    Receipts confirm SmolLM2-360M-Instruct, Qwen3-0.6B, Qwen3-1.7B.
  - `tokenizer.json` SHA-256 `d36d3e87…0f89` matches the gpu README claim.
  - `short.uorlut` magic `UORLUT01`, 2,156,480 bytes.
- Web end-to-end on :8931: `GET /` 200, `GET /api/weights` live
  inventory, `POST /api/vm/run` benign command returns output with
  exit 0, blocked command returns 403 with pattern/category,
  `POST /api/weights/verify` v9 returns 25/25 verified.
- Escript: `mix escript.build` produces `./mvm_ex`; `./mvmctl doctor`
  lists all six packs with shard counts; `machine run` prints guest
  output with exit 0; `weights verify v9` prints 25/25.
- Toolchain recovery (needed mid-task, recorded for the next VM swap):
  Erlang had been wiped; reinstalled OTP 25 from the Debian pool debs
  in `~/workspace/.tools/erlang-debs/` — base + crypto first, then
  asn1, public-key, ssl, runtime-tools, mnesia, xmerl, tftp, ftp,
  inets (the base package alone lacks `:inets`, which this app needs).
  Elixir 1.18.4 (OTP 25) was already present at
  `~/workspace/.tools/elixir-1.18.4/bin` from an earlier session; the
  1.17.3 copy installed during this task is a duplicate and can be
  removed.

## Not verified / limits (plain facts)

- v12/v13 weight pieces: fetched as companion sparse clones on their
  branches (`../lexlean-r4-weights-v12-360m`,
  `../lexlean-r4-weights-v13-qwen3-0.6b`,
  `../lexlean-r4-weights-v13-qwen3-1.7b`) — branch paths are root-level
  `weights/<pack>/`, not `gpu/weights/<pack>/`; an earlier attempt used
  the wrong path and was redone. Shard verification of those clones is
  pending at the time of this write; run
  `MVM_GPU_ROOT=../lexlean-r4-weights-<pack> ./mvmctl weights verify <pack>`
  to complete it.
- v10 XOR 2-of-3 parity reconstruction is NOT verified; parity files are
  only inventoried as present.
- Hypervisor backends are NOT ported (Firecracker/HVF/libkrun). The
  `:software` backend is an isolated OS process; it cannot prevent a
  guest process from opening a socket directly the way a hypervisor
  with no network device can. Direct egress from a software-backend
  guest is out of scope. Brokered egress (`MvmEx.Egress`) is enforced
  host-side.
- `MvmEx.Egress.fetch/3` uses TLS with verification disabled; integrity
  for fetched weight material comes from the manifest SHA-256 checks,
  not from TLS. Do not use it for secrets without a verifying client.
- Glob semantics: this port matches globs against the whole command
  string. The Rust `glob_match` semantics were not independently
  verified against the Rust source; if upstream matches substrings,
  glob entries would differ.
- The browser integer-inference engine (upstream `crates/wasm`) is not
  in this `gpu/` clone, so no in-browser inference run was performed
  here. The page loads weight metadata and runs host-side microVM
  sessions; it does not execute a model in the browser.
- CUDA trainers (`gpu/*.cu`) were not compiled or run: no GPU, no CUDA
  toolchain on this VM. Training/receipt claims are upstream's, repeated
  here only as manifest/receipt contents.
- No push has been made. Pushing this clone anywhere needs the owner to
  name the destination repo and supply a fresh key, as always.
