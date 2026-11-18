#!/bin/sh
# fetch-weights.sh — fetch v13 weight pieces on demand, then verify them.
# The pieces are NOT in this repo: v13-0.6B (429 MB) would push the repo
# just over GitHub's 1 GB recommendation, and v13-1.7B (1,140 MB) would
# push it past 2 GB. Manifests + receipts for both packs are in
# gpu/weights/v13_*/, so this script only fetches what the manifests name.
#
# LAYOUT CORRECTION (verified 2026-11-17): the v13 branches are FLAT at
# the branch root — manifest.json, piece_*.bin, parity_*.bin at the top
# level, NOT under weights/<pack>/. (The v12 branch IS under
# weights/v12_360m/; the branches differ.) Do NOT sparse-checkout
# `weights` here: that pattern matches nothing on a v13 branch and
# leaves the working tree empty with every file showing as deleted.
# This script clones without sparse checkout.
#
# Usage:
#   ./scripts/fetch-weights.sh v13_qwen3_0_6b [dest-dir]
#   ./scripts/fetch-weights.sh v13_qwen3_1_7b [dest-dir]
#   ./scripts/fetch-weights.sh all
# Dest defaults to ~/workspace/lexlean-r4-weights-<pack>.
# After fetching, verify with a staging dir, because mvmctl expects
# weights/<pack>/ under the gpu root and the branch is flat:
#   rm -rf /tmp/<pack>-gpu; mkdir -p /tmp/<pack>-gpu/weights/<pack>
#   for f in <dest>/*; do ln -s "$f" /tmp/<pack>-gpu/weights/<pack>/; done
#   MVM_GPU_ROOT=/tmp/<pack>-gpu ./mvm-elixir/mvmctl weights verify <pack>
set -e
REPO="https://github.com/Casey-allard/lexlean-r4.git"

fetch_one() {
  pack="$1"
  case "$pack" in
    v13_qwen3_0_6b) branch="weights-v13-qwen3-0.6b"; dir="lexlean-r4-weights-v13-qwen3-0.6b" ;;
    v13_qwen3_1_7b) branch="weights-v13-qwen3-1.7b"; dir="lexlean-r4-weights-v13-qwen3-1.7b" ;;
    *) echo "unknown pack: $pack (want v13_qwen3_0_6b or v13_qwen3_1_7b)" >&2; exit 1 ;;
  esac
  dest="${2:-$HOME/workspace/$dir}"
  if [ -d "$dest/.git" ]; then
    echo "already cloned: $dest — pulling $branch"
    git -C "$dest" fetch --depth 1 origin "$branch" 2>&1 | tail -n 2
    git -C "$dest" sparse-checkout disable 2>/dev/null || true
    git -C "$dest" reset --hard "origin/$branch" 2>&1 | tail -n 2
  else
    echo "cloning $branch (flat root, no sparse checkout) into $dest"
    git clone --depth 1 --branch "$branch" --filter=blob:none "$REPO" "$dest"
  fi
  echo "files: $(find "$dest" -maxdepth 1 -type f 2>/dev/null | wc -l)  size: $(du -sh "$dest" | cut -f1)"
  echo "verify with a staging dir (branch is flat, mvmctl wants weights/<pack>/):"
  echo "  rm -rf /tmp/$pack-gpu; mkdir -p /tmp/$pack-gpu/weights/$pack"
  echo "  for f in $dest/*; do ln -s \"\$f\" /tmp/$pack-gpu/weights/$pack/; done"
  echo "  MVM_GPU_ROOT=/tmp/$pack-gpu ./mvm-elixir/mvmctl weights verify $pack"
}

case "${1:-}" in
  all) fetch_one v13_qwen3_0_6b "${2:-}"; fetch_one v13_qwen3_1_7b "${3:-}" ;;
  v13_qwen3_0_6b|v13_qwen3_1_7b) fetch_one "$1" "${2:-}" ;;
  *) echo "usage: $0 v13_qwen3_0_6b|v13_qwen3_1_7b|all [dest-dir]" >&2; exit 1 ;;
esac
