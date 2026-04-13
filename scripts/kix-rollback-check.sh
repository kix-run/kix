#!/usr/bin/env bash
# kix-rollback-check.sh — regression test: A → B → A eval parity.
#
# Claim to protect: kix cluster evaluations are content-addressed pure
# functions of their inputs, so stepping *through* a variant and back
# produces a bit-identical rendered manifest tree. If this ever breaks,
# some state is leaking between evals (timestamps, IFD, caches, env
# vars), and rollback stops being exact — `kix rollback` could revert
# the activation's *logical* state but hash-differ, causing spurious
# deploys or drift.
#
# This test is eval-only (no cluster). It exercises:
#   - `nix build .#<variant>` round-trip determinism
#   - Content-addressed store path stability
#   - File-tree hash equality before/after a detour
#
# Strategy — use two existing flake outputs:
#   A = cluster-ludo-kind                   (baseline)
#   B = cluster-ludo-kind-gateway-migrate   (distinct desired state,
#                                            shared activation identity
#                                            "ludo-kind")
# Build A → B → A. Assert A and A' are bit-identical and differ from B.
#
# Usage:  ./scripts/kix-rollback-check.sh [--flake <flake>] [--variant-a <a>] [--variant-b <b>]

set -euo pipefail

FLAKE="./ludo"
VARIANT_A="cluster-ludo-kind"
VARIANT_B="cluster-ludo-kind-gateway-migrate"
# Use an array so `--extra-experimental-features` stays a single arg
# with a space-separated value — word-splitting would otherwise pass
# `nix-command` and `flakes` as separate positional args.
NIX_OPTS=(
    --extra-experimental-features "pipe-operators nix-command flakes"
)

while [ $# -gt 0 ]; do
    case "$1" in
        --flake) FLAKE="$2"; shift 2 ;;
        --variant-a) VARIANT_A="$2"; shift 2 ;;
        --variant-b) VARIANT_B="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

B='\033[0;34m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${B}==>${N} $*"; }
ok()   { echo -e "${G}✓${N} $*"; }
fail() { echo -e "${R}✗${N} $*" >&2; FAILED=1; }
FAILED=0

build() {
    local variant="$1"
    # `nix build` prints the out path with --print-out-paths. --no-link
    # skips creating ./result so we don't fight the three rounds for
    # the same symlink name. stderr is kept to surface genuine failures.
    nix build "${FLAKE}#${variant}" "${NIX_OPTS[@]}" --print-out-paths --no-link 2>/dev/null
}

# Canonical content hash of a store path's file tree.
# sha256 each file, LC_ALL=C sort for stable ordering, sha256 the list.
# Captures both file contents and the set of file names, ignores
# inode/mtime/fs metadata that nix doesn't content-address.
hash_tree() {
    local dir="$1"
    ( cd "$dir" && find . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{print $1}' )
}

# ─────────────────────────────────────────────────────────────────────────
log "round 1 — build baseline ($VARIANT_A)"
P1="$(build "$VARIANT_A")"
H1="$(hash_tree "$P1")"
echo "    store path: $P1"
echo "    tree hash : $H1"
echo

log "round 2 — build detour variant ($VARIANT_B)"
P2="$(build "$VARIANT_B")"
H2="$(hash_tree "$P2")"
echo "    store path: $P2"
echo "    tree hash : $H2"
echo

log "round 3 — rebuild baseline ($VARIANT_A) — must match round 1"
P3="$(build "$VARIANT_A")"
H3="$(hash_tree "$P3")"
echo "    store path: $P3"
echo "    tree hash : $H3"
echo

# ─── assertions ─────────────────────────────────────────────────────────

if [ "$H1" = "$H2" ]; then
    fail "variants $VARIANT_A and $VARIANT_B hashed identically — test is vacuous (pick a more distinctive variant B)"
else
    ok "variants produce distinct hashes (test is non-trivial)"
fi

if [ "$P1" = "$P3" ]; then
    ok "nix store paths match across the round trip: $P1"
else
    fail "nix store path drifted: round1=$P1 round3=$P3"
fi

if [ "$H1" = "$H3" ]; then
    ok "content-hash parity: file-tree hash is bit-identical after A → B → A"
else
    fail "content-hash parity broken: H1=$H1 H3=$H3"
    fail "diff (round 1 vs round 3):"
    diff -rq "$P1" "$P3" || true
fi

# ─── byte-level manifest check ──────────────────────────────────────────
# Extra paranoia — explicitly check that every manifest file renders
# byte-identical. `hash_tree` already covers this but `diff -rq` gives
# a human-readable report when it doesn't.
log "byte-level diff (round 1 vs round 3)"
if diff -rq "$P1" "$P3" >/dev/null 2>&1; then
    ok "no byte-level differences"
else
    fail "byte-level diff found:"
    diff -rq "$P1" "$P3" || true
fi

echo
if [ "$FAILED" -eq 0 ]; then
    ok "rollback content-hash parity check: PASSED"
    exit 0
else
    echo -e "${R}rollback content-hash parity check: FAILED${N}" >&2
    exit 1
fi
