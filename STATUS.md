# STATUS — lexlean-r4-beam

Date: 2026-11-17. All checks below ran on this VM unless stated otherwise.

## What this repo is

One organized repo cut from two upstreams, by the GitHub size rule:

- Source A: Casey-allard/lexlean-r4, main `ed3ba33`, `gpu/` only
  (sparse clone at `~/workspace/lexlean-r4-gpu`, 500 MB).
- Source B: Casey-allard/mvm, Apache-2.0, ported to Elixir/OTP as
  `mvm-elixir/` (local commit `4867c9b` in the source clone).
- Cut rule: GitHub blocks a single file over 100 MiB, warns above
  50 MiB, recommends a repo under 1 GB total, strongly under 5 GB,
  2 GB per push. This repo: 589 MB total, 885 files, largest file
  2,156,480 B (`gpu/short.uorlut`), 0 files over 50 MB.
- Size math: minimal (v8/v9/v10) 308 MB + v12 pieces 282 MB = 590 MB.
  Adding v13-0.6B (429 MB) would make ~1.02 GB, just over the 1 GB
  recommendation. Adding v13-1.7B (1,140 MB) would make ~2.05 GB,
  past the recommendation and the per-push limit. So v12 is in,
  v13 is manifests + receipts + fetch script only.

## Verification performed on this VM

- `mix test` in `mvm-elixir/`: **46 tests, 0 failures** (15.9 s).
  Was 45 in the source clone; +1 is the new v12 verify test.
  Covers: JSON, plan sign/verify + tamper, audit chain + tamper/drop,
  gate (all 13 blocklist entries), lifecycle, egress, VM exec/gate/
  timeout/mount, pool SLO/cap/reap, agent, weights (see below).
- `mix escript.build`: builds `./mvm_ex`; `./mvmctl doctor` lists
  all six packs: v8 360/360, v9 25/25, v10 73/73, v12_360m 188/188,
  v13_qwen3_0_6b 0/410, v13_qwen3_1_7b 0/1088.
- Weights, hash-verified with `./mvmctl weights verify <pack>`:
  - v8: 360/360 ok; stitch matches container SHA-256
    `34259da9…ee5e48`, 188,728,472 bytes.
  - v9: 25/25 ok.
  - v10: 73/73 data shards ok; 37 parity files present.
  - v12_360m: **188/188 ok** (new in this repo; pieces copied from
    branch `weights-v12-360m`, 285 files in `gpu/weights/v12_360m/`
    = 188 shards + 97 parity + manifest + stitch manifest + receipt).
  - v13: 0 pieces on disk; manifests + receipts only.
  - `tokenizer.json` SHA-256 `d36d3e87…0f89` matches the upstream
    gpu README claim. `short.uorlut` magic `UORLUT01`, 2,156,480 B.
- Web end-to-end on :8931: `GET /` 200, `GET /api/weights` live
  inventory, `POST /api/vm/run` benign returns output + exit 0,
  `rm -rf /` returns 403 with pattern/category `destructive`,
  `POST /api/weights/verify` v12_360m returns 188/188 verified.
- `machine run` via escript prints guest output, exit 0.
- Rust compile check, `rustc` edition 2021 `-O` from
  `~/workspace/.tools/cargo/bin/`, in `gpu/rust/`:
  - PASS (7 binaries): build_v9_corpus, build_v10_corpus,
    build_v11_corpus, fetch_hf_datasets, recompile_r4_teacher,
    train_general_glm, train_v11.
  - PASS as libs: bpe_json, glm_corpus, glm_expanded_corpus.
  - Modules, fail alone / pass via parent: glm_reasoner_template
    (included by train_general_glm), v10_corpus_ab + v10_corpus_cde
    (included by build_v10_corpus, which passes).
  - FAIL, named reasons, upstream code NOT edited:
    - recompile_holo_v13: needs external `sha2` crate
      (`use sha2::{Digest, Sha256}` unresolved by bare rustc).
    - train_native_q31_r4 + train_uorlut_v8: need
      `../crates/wasm/src/lexlean_generated.rs`, a file from upstream
      `crates/wasm`, not in the `gpu/` clone.
- Licenses copied verbatim from upstream root: LICENSE-MIT
  SHA-256 `b65b82603a4875244eaecc241d1666217ae7d9f8bf4ad3e7b1ac88d8888126ee`,
  LICENSE-APACHE SHA-256
  `62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a`.
  Nothing relicensed.

## Changes vs the source clone (this repo only)

- `mvm-elixir/lib/mvm_ex/weights.ex`: receipt paths updated to the
  new layout (`receipts/rtx5090_…`, `receipts/rtx4090_…`), v12 doc
  updated (pieces ARE in this repo), `gpu_root` fallback updated
  from `lexlean-r4-gpu` to `lexlean-r4-beam`.
- `mvm-elixir/test/weights_test.exs`: v12 shards_present_count
  0 → 188, plus a new v12 verify test (188/188). v13 still 0.
- `mvm-elixir/README.md` + `mvm-elixir/STATUS.md`: see the note
  at the top of each file — the beam-repo state supersedes the
  source-clone state for v12.
- Receipts moved `gpu/*.json` → `gpu/receipts/*.json`; CUDA
  `gpu/*.cu` → `gpu/cuda/`; Rust `gpu/*.rs` → `gpu/rust/`;
  upstream gpu README kept verbatim at `docs/upstream-gpu-README.md`.
- No upstream source file was edited to make it compile or pass.

## Not verified / limits (plain facts)

- v13 pieces: NOT verified here. The v13-0.6B branch clone was still
  downloading at cut time (`.git` 477 MB, working tree not checked
  out, `index.lock` present); v13-1.7B had not started. Use
  `scripts/fetch-weights.sh` to fetch and verify on demand.
- v10 XOR 2-of-3 parity reconstruction is NOT verified; parity files
  are only inventoried as present. v12 parity files are likewise
  inventoried, not reconstruction-verified.
- CUDA trainers (`gpu/cuda/*.cu`) were not compiled or run: no GPU,
  no CUDA toolchain on this VM. Training/receipt claims are
  upstream's, repeated only as receipt contents.
- Hypervisor backends are NOT ported (Firecracker/HVF/libkrun).
  Backend here is `:software`, an isolated OS process; it cannot
  prevent a guest process from opening a socket directly the way a
  hypervisor with no network device can. Brokered egress is enforced
  host-side.
- `MvmEx.Egress.fetch/3` uses TLS with verification disabled;
  integrity comes from manifest SHA-256, not TLS.
- Glob semantics: whole-command matching; Rust `glob_match`
  semantics not independently verified.
- The browser integer-inference engine (upstream `crates/wasm`) is
  not in this repo, so no in-browser inference run was performed.
  The page serves weight metadata and runs host-side microVM sessions.
- No push has been made. Pushing this repo anywhere needs the owner
  to name the destination repo and supply a fresh key, as always.
