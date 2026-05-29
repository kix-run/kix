# Offline driver for the captures pipeline.
#
# Wraps the shared library into one host-side shell script
# (`nix run ./docs#regen-captures-offline`). The script:
#
#   1. For each manifest group with any `offline` steps, prepares a
#      fresh workspace (kix-examples + overlay + setup mutations) and
#      runs every offline step in declaration order against it. Each
#      group gets its own workspace; no shared state.
#   2. Stages every captured sidecar to a tempdir, then compares the
#      drift view against the checked-in tree under
#      `docs/src/command-output/`. Diffs are printed; `--apply` writes
#      them, `--check` exits non-zero on any diff.
#
# Used by CI's `pages.yml` (`--check`) to gate stale sidecars and by
# maintainers locally (`--apply`) to regenerate them. Mirrors
# `captures-live.nix`'s shape; the only fundamental difference is no
# kind cluster — `kix` is invoked against the workspace directly, with
# `kixpkgs` repointed via `--override-input` so the eval stays clear of
# the workspace flake.lock's pinned-but-stale kixpkgs rev.

{
  pkgs,
  lib,
  kix,
  kixExamples,
  kixpkgsSrc,
}:

let
  capturesLib = import ./captures-lib.nix {
    inherit
      pkgs
      lib
      kix
      kixExamples
      kixpkgsSrc
      ;
  };

  inherit (capturesLib)
    manifest
    mkStepShell
    workspaceSetupShell
    kixOverrideArgs
    ;

  # Offline kix invocation. `--no-color` keeps the rendered docs free
  # of terminal-width-dependent escapes (the live driver wants ANSI so
  # uses a PTY wrap; offline steps are simpler text output and don't).
  # `--no-cache` so nothing leaks between captures. `kixOverrideArgs`
  # pins the workspace's kixpkgs input to the in-store source.
  invocationFor =
    step:
    let
      bin = lib.head step.run;
    in
    if bin == "kix" then
      ''kix --no-color --no-cache --flake "$workspace" ${kixOverrideArgs}''
    else
      throw "captures-offline: only `kix` is allowed offline (got `${bin}`); move kubectl/live commands to the live array";

  mkGroupBlock =
    group:
    let
      offlineSteps = group.offline or [ ];
      stepShellBlocks = lib.concatMapStringsSep "\n" (
        step:
        mkStepShell {
          inherit group step;
          inherit invocationFor;
          generator = "offline";
        }
      ) offlineSteps;
    in
    ''
      printf '→ workspace for %s\n' ${lib.escapeShellArg group.group}
      workspace=$(mktemp -d -t kix-docs-offline-ws.XXXXXX)
      ws_dirs+=("$workspace")

      ${workspaceSetupShell group}

      ${stepShellBlocks}
    '';

  groupsWithOffline = builtins.filter (g: (g.offline or [ ]) != [ ]) manifest;

  groupBlocks = lib.concatMapStringsSep "\n" mkGroupBlock groupsWithOffline;

  scriptDeps = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.python3
    pkgs.jq
    pkgs.gnutar
    pkgs.diffutils
    pkgs.findutils
    kix
  ];

  script = pkgs.writeShellScript "regen-captures-offline" ''
    set -euo pipefail
    export PATH=${scriptDeps}:$PATH
    export NO_COLOR=1

    apply=0
    check=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --apply) apply=1 ;;
        --check) check=1 ;;
        -h|--help)
          cat <<USAGE
    regen-captures-offline — capture every `offline` step in
    docs/nix/captures.nix, diff against the checked-in sidecars,
    optionally apply.

    Usage:
      nix run ./docs#regen-captures-offline
      nix run ./docs#regen-captures-offline -- --apply
      nix run ./docs#regen-captures-offline -- --check
    USAGE
          exit 0
          ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
      esac
      shift
    done

    repo_root=$(pwd)
    if [ ! -f "$repo_root/docs/package.json" ]; then
      echo "error: run from the kixpkgs repo root" >&2
      exit 1
    fi
    target_dir="$repo_root/docs/src/command-output"

    stagingDir=$(mktemp -d -t kix-docs-offline-staging.XXXXXX)
    ws_dirs=()

    cleanup() {
      for d in "''${ws_dirs[@]:-}"; do rm -rf "$d"; done
      rm -rf "$stagingDir"
    }
    trap cleanup EXIT

    ${groupBlocks}

    # Drift comparison: each captured sidecar is reduced to a drift
    # view (id/command/exitCode/stdoutDrift/stderrDrift) before
    # diffing against the checked-in copy. Offline captures are
    # deterministic and the display + drift views should match, but
    # we still diff the drift view to match the live driver's shape.
    drift_view() {
      jq -S '{
        id, group, page, cwd, generator,
        commands: (.commands | map({
          command, exitCode,
          stdoutDrift: (.stdoutDrift // ""),
          stderrDrift: (.stderrDrift // "")
        }))
      }' "$1"
    }
    diff_report=$(mktemp -t kix-docs-offline-diff.XXXXXX)
    changed=0
    while IFS= read -r -d "" sidecar; do
      rel=''${sidecar#$stagingDir/}
      target="$target_dir/$rel"
      if [ ! -f "$target" ]; then
        printf 'NEW  %s\n' "$rel" >> "$diff_report"
        changed=$((changed + 1))
        continue
      fi
      fresh_view=$(drift_view "$sidecar")
      checked_view=$(drift_view "$target")
      if [ "$fresh_view" != "$checked_view" ]; then
        diff -u --label "checked-in/$rel (drift view)" --label "fresh/$rel (drift view)" \
          <(printf '%s\n' "$checked_view") <(printf '%s\n' "$fresh_view") \
          >> "$diff_report" || true
        changed=$((changed + 1))
      fi
    done < <(find "$stagingDir" -type f -name '*.json' -print0)

    if [ "$changed" -eq 0 ]; then
      printf '→ no offline sidecar drift\n'
      rm -f "$diff_report"
      exit 0
    fi

    if [ "$check" -eq 1 ]; then
      cat "$diff_report"
      echo "FAIL: $changed offline sidecar(s) would change — run \`nix run ./docs#regen-captures-offline -- --apply\` to refresh" >&2
      rm -f "$diff_report"
      exit 3
    fi

    cat "$diff_report"
    rm -f "$diff_report"

    if [ "$apply" -eq 0 ]; then
      printf '\nApply %d change(s) to %s? [y/N] ' "$changed" "$target_dir"
      read -r reply
      case "$reply" in y|Y|yes) ;; *) echo "aborted"; exit 0 ;; esac
    fi

    while IFS= read -r -d "" sidecar; do
      rel=''${sidecar#$stagingDir/}
      mkdir -p "$target_dir/$(dirname "$rel")"
      cp "$sidecar" "$target_dir/$rel"
    done < <(find "$stagingDir" -type f -name '*.json' -print0)
    printf '→ wrote %d sidecar(s)\n' "$changed"
  '';
in
{
  inherit script;
  app = {
    type = "app";
    program = toString script;
  };
}
