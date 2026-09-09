# Live driver for the captures pipeline.
#
# Wraps the shared library into one host-side shell script
# (`nix run ./docs#regen-captures`). The script:
#
#   1. Creates a dedicated `kind-kix-docs` kind cluster.
#   2. For each manifest group with any `live` steps, prepares a fresh
#      workspace (kix-examples + overlay + setup mutations) and runs
#      every live step in declaration order. The kind cluster is
#      SHARED across groups so deploys accumulate, matching what a
#      reader walking the tutorial path sees.
#   3. Stages every captured sidecar to a tempdir, then compares the
#      drift view against the checked-in tree under
#      `docs/src/command-output/`. Diffs are printed; `--apply`
#      writes them, `--check` exits non-zero on any diff.
#
# Trust boundary: the script writes its own KUBECONFIG and pins the
# context to `kind-kix-docs`. All kix and kubectl invocations get
# `--context kind-kix-docs` so they refuse to talk to any other
# cluster the maintainer might have set as current.

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

  kubeContext = "kind-kix-docs";
  kindClusterName = "kix-docs";

  # Live kix/kubectl invocation. PTY wrapping via `script -q /dev/null`
  # so kix/kubectl produce ANSI colour even though we redirect to a
  # file (their output detects non-TTY and disables colour otherwise).
  # --context is injected uniformly to keep the trust boundary tight.
  # `kixOverrideArgs` repoints the workspace's kixpkgs input to the
  # in-store source.
  invocationFor =
    step:
    let
      bin = lib.head step.run;
    in
    if bin == "kix" && step ? stdoutJq then
      ''kix --no-color --no-cache --context "${kubeContext}" --flake "$workspace" ${kixOverrideArgs}''
    else if bin == "kix" then
      ''script -q /dev/null kix --no-cache --context "${kubeContext}" --flake "$workspace" ${kixOverrideArgs}''
    else if bin == "kubectl" && step ? stdoutJq then
      ''kubectl --context "${kubeContext}"''
    else if bin == "kubectl" then
      ''script -q /dev/null kubectl --context "${kubeContext}"''
    else
      throw "captures-live: unknown binary `${bin}` (extend invocationFor)";

  mkGroupBlock =
    group:
    let
      liveSteps = group.live or [ ];
      stepShellBlocks = lib.concatMapStringsSep "\n" (
        step:
        mkStepShell {
          inherit group step;
          inherit invocationFor;
          generator = "live";
        }
      ) liveSteps;
    in
    ''
      if [ -z "$group_filter" ] || [ "$group_filter" = ${lib.escapeShellArg group.group} ]; then
        printf '→ workspace for %s\n' ${lib.escapeShellArg group.group}
        workspace=$(mktemp -d -t kix-docs-ws.XXXXXX)
        ws_dirs+=("$workspace")

        ${workspaceSetupShell group}

        ${stepShellBlocks}
      fi
    '';

  groupsWithLive = builtins.filter (g: (g.live or [ ]) != [ ]) manifest;

  groupBlocks = lib.concatMapStringsSep "\n" mkGroupBlock groupsWithLive;

  scriptDeps = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.python3
    pkgs.jq
    pkgs.kind
    pkgs.kubectl
    pkgs.gnutar
    pkgs.diffutils
    pkgs.findutils
    kix
  ];

  script = pkgs.writeShellScript "regen-captures" ''
    set -euo pipefail
    export PATH=${scriptDeps}:$PATH

    keep_cluster=0
    apply=0
    check=0
    group_filter=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --keep-cluster) keep_cluster=1 ;;
        --apply)        apply=1 ;;
        --check)        check=1 ;;
        --group)
          shift
          if [ $# -eq 0 ]; then
            echo "--group requires a capture group name" >&2
            exit 2
          fi
          group_filter="$1"
          ;;
        -h|--help)
          cat <<USAGE
    regen-captures — capture every `live` step in docs/nix/captures.nix
    against a dedicated kind cluster, diff against the checked-in
    sidecars, optionally apply.

    Usage:
      nix run ./docs#regen-captures
      nix run ./docs#regen-captures -- --apply
      nix run ./docs#regen-captures -- --check
      nix run ./docs#regen-captures -- --group how-to/application-health-check --apply
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

    KUBECONFIG=$(mktemp -t kix-docs-kubeconfig.XXXXXX)
    export KUBECONFIG
    stagingDir=$(mktemp -d -t kix-docs-staging.XXXXXX)
    ws_dirs=()

    cleanup() {
      for d in "''${ws_dirs[@]:-}"; do rm -rf "$d"; done
      rm -rf "$stagingDir"
      rm -f "$KUBECONFIG"
      if [ "$keep_cluster" -eq 0 ]; then
        kind delete cluster --name "${kindClusterName}" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup EXIT

    # Spin up the kind cluster.
    if kind get clusters | grep -qx "${kindClusterName}"; then
      kind delete cluster --name "${kindClusterName}"
    fi
    printf '→ creating %s kind cluster\n' "${kindClusterName}"
    kind create cluster --name "${kindClusterName}" --kubeconfig "$KUBECONFIG"

    current_ctx=$(kubectl config current-context)
    if [ "$current_ctx" != "${kubeContext}" ]; then
      echo "fatal: expected current-context ${kubeContext}, got $current_ctx" >&2
      exit 4
    fi

    ${groupBlocks}

    # Drift comparison: each captured sidecar is reduced to a drift
    # view (id/command/exitCode/stdoutDrift/stderrDrift) before diffing
    # against the checked-in copy. The display `stdout`/`stderr` is
    # ignored because it retains per-run noise (real durations, IPs,
    # pod hashes) that `<Command>` renders verbatim for fidelity.
    drift_view() {
      jq -S '{
        id, group, page, cwd, generator,
        outputExcerpt: (.outputExcerpt // false),
        commands: (.commands | map({
          command, exitCode,
          stdoutDrift: (.stdoutDrift // ""),
          stderrDrift: (.stderrDrift // "")
        }))
      }' "$1"
    }
    diff_report=$(mktemp -t kix-docs-diff.XXXXXX)
    changed=0
    while IFS= read -r -d "" sidecar; do
      rel=''${sidecar#$stagingDir/}
      target="$target_dir/$rel"
      if [ ! -f "$target" ]; then
        printf 'NEW  %s\n' "$rel" >> "$diff_report"
        changed=$((changed + 1))
        continue
      fi
      # Honour `skipDriftCheck = true` (see captures.nix). Same
      # rationale as the offline driver — sidecar still gets
      # rewritten by --apply, just isn't gated by --check.
      if [ "$(jq -r '.skipDriftCheck // false' "$sidecar")" = "true" ]; then
        if [ "$apply" -eq 1 ]; then
          printf 'REFRESH  %s (drift check skipped)\n' "$rel" >> "$diff_report"
          changed=$((changed + 1))
        fi
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
      printf '→ no live sidecar drift\n'
      rm -f "$diff_report"
      exit 0
    fi

    if [ "$check" -eq 1 ]; then
      cat "$diff_report"
      echo "FAIL: $changed sidecar(s) would change" >&2
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
