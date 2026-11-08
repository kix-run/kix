#!/usr/bin/env bash
# Run an unpacked Kix release archive on a machine without Nix: `kix doctor`,
# then `kix build` of a cluster without Helm and of one with Helm.
#
# usage: cli/runtime/without-nix.sh <unpacked-archive> <kixpkgs-checkout>
#
# <unpacked-archive> holds bin/kix and libexec/kix. <kixpkgs-checkout> must be
# a git clone, not a git worktree, because only the checkout is visible to
# Kix.
#
# On Linux, Kix runs in a plain Ubuntu container, which has no /nix. Only the
# archive, the checkout, and the host's CA bundle are mounted into it.
#
# On macOS, sandbox-exec denies every access to /nix. Kix runs with an empty
# environment except for PATH=/usr/bin:/bin and a fresh HOME and XDG
# folders, and its local store sits under the resolved temporary folder
# (/private/var/...), as it would for a user whose TMPDIR is a link.
#
# NIX_CONFIG passes through, so CI can give Nix a GitHub token for fetching
# the flake inputs.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  sed -n '5p' "$0" >&2
  exit 2
fi

archive="$(cd "$1" && pwd -P)"
repo="$(cd "$2" && pwd -P)"

if [[ ! -x "$archive/bin/kix" || ! -f "$archive/libexec/kix/manifest.json" ]]; then
  echo "$archive does not hold bin/kix and libexec/kix/manifest.json" >&2
  exit 2
fi
if [[ ! -d "$repo/.git" ]]; then
  echo "$repo is not a git clone (a worktree's .git file points outside it)" >&2
  exit 2
fi

# Runs inside the isolation, with $KIX set to the `kix` command.
checks='
set -eu
cd "$REPO"
if [ -e /nix ]; then
  echo "/nix is visible, so this check proves nothing" >&2
  exit 1
fi
"$KIX" doctor
"$KIX" --no-color build minimal >"$HOME/minimal.yaml"
"$KIX" --no-color build helm >"$HOME/helm.yaml"
grep -q "^kind:" "$HOME/minimal.yaml"
grep -q "^kind:" "$HOME/helm.yaml"
echo "built minimal ($(grep -c "^kind:" "$HOME/minimal.yaml") objects) and helm ($(grep -c "^kind:" "$HOME/helm.yaml") objects) without Nix"
'

case "$(uname -s)" in
  Linux)
    # A link such as NixOS's /etc/ssl/certs resolves on the host, so only
    # the file itself is mounted.
    certs="$(readlink -f /etc/ssl/certs/ca-certificates.crt)"
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp/home \
      -e KIX=/opt/kix/bin/kix \
      -e REPO=/src \
      -e NIX_CONFIG \
      -v "$archive:/opt/kix:ro" \
      -v "$repo:/src" \
      -v "$certs:/etc/ssl/certs/ca-certificates.crt:ro" \
      ubuntu:24.04 \
      bash -c 'mkdir -p "$HOME" && '"$checks"
    ;;
  Darwin)
    tmp="$(cd "$(mktemp -d)" && pwd -P)"
    trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/home" "$tmp/cache" "$tmp/config" "$tmp/data" "$tmp/state"
    profile='(version 1)
(allow default)
(deny file-read* file-write* (subpath "/nix"))'
    env -i \
      PATH=/usr/bin:/bin \
      HOME="$tmp/home" \
      XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" \
      XDG_DATA_HOME="$tmp/data" \
      XDG_STATE_HOME="$tmp/state" \
      TMPDIR="$tmp" \
      KIX_STORE_ROOT="$tmp/store" \
      KIX="$archive/bin/kix" \
      REPO="$repo" \
      ${NIX_CONFIG:+NIX_CONFIG="$NIX_CONFIG"} \
      sandbox-exec -p "$profile" /bin/bash -c "$checks"
    ;;
  *)
    echo "unsupported system $(uname -s)" >&2
    exit 2
    ;;
esac
