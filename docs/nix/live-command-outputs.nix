# Live command output generator: spin up a dedicated kind cluster, run a
# sequence of `kix` commands against it, sanitise via the transforms library,
# and emit JSON sidecars next to the offline outputs.
#
# Public entry point: `nix run ./docs#regen-live-docs`.
#
# Design notes:
#
# - Trust boundary. The script writes its own KUBECONFIG and pins the context
#   to `kind-kix-docs`. It refuses to touch any other context or to invoke
#   kubectl without `--context=kind-kix-docs`.
# - One workspace per run. The script copies `kix-examples` into a temp dir
#   so the live commands write to a clean checkout (avoids polluting the
#   maintainer's working copy).
# - Capture, transform, write. Each command's stdout/stderr/exitCode is
#   captured raw, passed through the named transforms in order, and emitted
#   as a JSON sidecar matching the offline schema.
# - Diff, don't auto-overwrite. The script writes to a staging directory and
#   prints `diff -ru` against the checked-in tree, then asks before copying.
#   Use `--apply` to skip the prompt, `--check` to fail on any diff.

{
  pkgs,
  lib,
  kix,
  kixExamples,
}:

let
  groups = import ./live-command-outputs-manifest.nix;

  transforms = import ./output-transforms.nix { inherit lib; };

  sanitizeName = lib.replaceStrings [ "/" ] [ "-" ];

  mkDisplayCommand =
    command:
    lib.concatStringsSep " " (
      [ (command.cmd or "kix") ]
      ++ (map (arg: if lib.hasInfix " " arg then "'${arg}'" else arg) command.args)
    );

  commandEntries = lib.concatMap (
    group:
    lib.imap0 (
      index: command:
      command
      // {
        inherit (group) group page cwd;
        inherit index;
        id = "${group.group}/${command.name}";
        cmd = command.cmd or "kix";
        displayCommand = command.displayCommand or (mkDisplayCommand command);
        groupTag = group.group;
      }
    ) group.commands
  ) groups;

  mkSedPipeline =
    names:
    if names == [ ] then
      "cat"
    else
      lib.concatMapStringsSep " | " (
        name: ''sed -E ${lib.escapeShellArg transforms.programs.${name}}''
      ) names;

  displayPipeline = mkSedPipeline transforms.displayTransforms;
  baseDriftPipeline = mkSedPipeline transforms.driftTransforms;

  # Per-entry drift pipeline. When `sortLines` is true (the default), append
  # a `sort` stage so non-deterministic line ordering (e.g. concurrent
  # resource events in `kix deploy`) doesn't surface as drift. Opt out for
  # output where ordering carries meaning (tree views, ordered plans).
  driftPipelineFor =
    entry: if (entry.sortLines or true) then "${baseDriftPipeline} | sort" else baseDriftPipeline;

  # Generate the per-command capture+sanitise+emit shell block. We inline
  # everything in Nix so the runtime script has no manifest parsing — each
  # capture is its own deterministic block.
  # Per-binary invocation. Each entry runs as `<binary> <auto-flags> <args>`:
  #   kix     → ${kix}/bin/kix --no-cache --context <ctx>
  #   kubectl → kubectl --context <ctx>     (relies on system PATH)
  # Add new tools here. `--context` is injected uniformly so commands target
  # the dedicated kind-kix-docs cluster, not whatever happens to be the
  # caller's current context.
  invocationFor =
    cmd:
    if cmd == "kix" then
      ''${kix}/bin/kix --no-cache --context "${kubeContext}"''
    else if cmd == "kubectl" then
      ''kubectl --context "${kubeContext}"''
    else
      throw "live-command-outputs: unknown cmd '${cmd}' (extend invocationFor)";

  mkCaptureBlock =
    entry:
    let
      escArgs = lib.escapeShellArgs entry.args;
      outputPath = "${entry.id}.json";
      invocation = invocationFor entry.cmd;
      driftPipeline = driftPipelineFor entry;
    in
    ''
      log_command "${entry.id}" "${entry.displayCommand}"

      stdout_raw=$(mktemp)
      stderr_raw=$(mktemp)
      stdout_display=$(mktemp)
      stderr_display=$(mktemp)
      stdout_drift=$(mktemp)
      stderr_drift=$(mktemp)

      # PTY-wrap the binary so it produces ANSI colour output even though
      # we redirect to a file. `script -q /dev/null <cmd>` allocates a
      # pseudo terminal; without it, kix/kubectl detect the non-TTY pipe
      # and disable colour.
      set +e
      ( cd "$workspace" && \
        env KUBECONFIG="$KUBECONFIG" \
            script -q /dev/null \
              ${invocation} ${escArgs} \
        ) > "$stdout_raw" 2> "$stderr_raw"
      exit_code=$?
      set -e

      # Display version: only terminal normalisation. This is what the docs
      # render — real durations, IPs, hashes etc. are preserved verbatim.
      <"$stdout_raw" ${displayPipeline} > "$stdout_display"
      <"$stderr_raw" ${displayPipeline} > "$stderr_display"
      # Drift version: display normalisation plus volatile-value redactions
      # and whitespace folding. The regen tool compares THIS field, so
      # column-width / colour / per-run noise doesn't trigger drift.
      <"$stdout_raw" ${driftPipeline}   > "$stdout_drift"
      <"$stderr_raw" ${driftPipeline}   > "$stderr_drift"

      mkdir -p "$staging/$(dirname ${outputPath})"
      jq -n \
        --arg id "${entry.id}" \
        --arg group "${entry.groupTag}" \
        --arg page "${entry.page}" \
        --arg command "${entry.displayCommand}" \
        --arg cwd "${entry.cwd}" \
        --arg generator "live" \
        --argjson exitCode "$exit_code" \
        --rawfile stdout "$stdout_display" \
        --rawfile stderr "$stderr_display" \
        --rawfile stdoutDrift "$stdout_drift" \
        --rawfile stderrDrift "$stderr_drift" \
        '{
          id: $id,
          group: $group,
          page: $page,
          cwd: $cwd,
          generator: $generator,
          commands: [{
            command: $command,
            stdout: $stdout,
            stderr: $stderr,
            stdoutDrift: $stdoutDrift,
            stderrDrift: $stderrDrift,
            exitCode: $exitCode
          }]
        }' > "$staging/${outputPath}"

      rm -f "$stdout_raw" "$stderr_raw" \
            "$stdout_display" "$stderr_display" \
            "$stdout_drift" "$stderr_drift"
    '';

  kubeContext = "kind-kix-docs";
  kindClusterName = "kix-docs";

  captureBlocks = lib.concatMapStringsSep "\n" mkCaptureBlock commandEntries;

  scriptDeps = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gnused
    pkgs.jq
    pkgs.kind
    pkgs.kubectl
    pkgs.gnutar
    pkgs.diffutils
    kix
  ];

  script = pkgs.writeShellScript "regen-live-docs" ''
    set -euo pipefail
    export PATH=${scriptDeps}:$PATH

    keep_cluster=0
    apply=0
    check=0
    workspace_keep=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --keep-cluster) keep_cluster=1 ;;
        --apply)        apply=1 ;;
        --check)        check=1 ;;
        --keep-workspace) workspace_keep=1 ;;
        -h|--help)
          cat <<USAGE
    regen-live-docs — regenerate live command output JSON sidecars.

    Usage:
      nix run ./docs#regen-live-docs            # capture, diff, prompt before copying
      nix run ./docs#regen-live-docs -- --apply # capture and copy without prompting
      nix run ./docs#regen-live-docs -- --check # exit non-zero if any sidecar would change

    Flags:
      --keep-cluster     leave the kind cluster running after the run
      --keep-workspace   keep the temp kix-examples copy on disk
    USAGE
          exit 0
          ;;
        *)
          echo "unknown arg: $1" >&2
          exit 2
          ;;
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
    staging=$(mktemp -d -t kix-docs-staging.XXXXXX)
    workspace=$(mktemp -d -t kix-docs-workspace.XXXXXX)
    log_file=$(mktemp -t kix-docs-log.XXXXXX)

    cleanup() {
      [ "$workspace_keep" -eq 1 ] || rm -rf "$workspace"
      [ "$workspace_keep" -eq 1 ] || rm -rf "$staging"
      rm -f "$KUBECONFIG" "$log_file"
      if [ "$keep_cluster" -eq 0 ]; then
        kind delete cluster --name "${kindClusterName}" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup EXIT

    log() { printf '→ %s\n' "$*" | tee -a "$log_file"; }
    log_command() {
      printf '  capturing %s :: %s\n' "$1" "$2" | tee -a "$log_file"
    }

    # ---- workspace: writable copy of kix-examples ---------------------------
    log "preparing kix-examples workspace at $workspace"
    cp -r --no-preserve=mode ${kixExamples}/. "$workspace/"
    chmod -R u+w "$workspace"

    # ---- cluster: tear down stale, create fresh -----------------------------
    if kind get clusters | grep -qx "${kindClusterName}"; then
      log "deleting stale ${kindClusterName} kind cluster"
      kind delete cluster --name "${kindClusterName}"
    fi
    log "creating ${kindClusterName} kind cluster"
    kind create cluster --name "${kindClusterName}" --kubeconfig "$KUBECONFIG"

    current_ctx=$(kubectl config current-context)
    if [ "$current_ctx" != "${kubeContext}" ]; then
      echo "fatal: expected current-context ${kubeContext}, got $current_ctx" >&2
      exit 4
    fi
    log "kube context locked to ${kubeContext}"

    # ---- captures -----------------------------------------------------------
    ${captureBlocks}

    # ---- diff / apply / check ----------------------------------------------
    # Diff each captured sidecar against its checked-in counterpart only —
    # do NOT touch offline-generated files. The set of paths we manage is
    # determined by the manifest, materialised under $staging.
    #
    # We compare a "drift view" of each JSON: id/command/exitCode plus the
    # `stdoutDrift` / `stderrDrift` fields (volatile values normalised). The
    # display `stdout` / `stderr` fields are deliberately ignored because
    # they retain per-run noise (real durations, IPs, pod hashes) that the
    # `<Command>` component then renders for fidelity.
    drift_view() {
      jq -S '{
        id, group, page, cwd, generator,
        commands: (.commands | map({
          command,
          exitCode,
          stdoutDrift: (.stdoutDrift // ""),
          stderrDrift: (.stderrDrift // "")
        }))
      }' "$1"
    }
    log "comparing staging against $target_dir (drift view, live paths only)"
    diff_report=$(mktemp -t kix-docs-diff.XXXXXX)
    changed=0
    while IFS= read -r -d "" sidecar; do
      rel=''${sidecar#$staging/}
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
    done < <(find "$staging" -type f -name '*.json' -print0)

    if [ "$changed" -eq 0 ]; then
      log "no changes — checked-in sidecars match capture"
      rm -f "$diff_report"
      exit 0
    fi

    if [ "$check" -eq 1 ]; then
      cat "$diff_report"
      echo "FAIL: $changed sidecar(s) would change — checked-in copies are stale" >&2
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

    log "writing $changed sidecar(s) into $target_dir"
    while IFS= read -r -d "" sidecar; do
      rel=''${sidecar#$staging/}
      mkdir -p "$target_dir/$(dirname "$rel")"
      cp "$sidecar" "$target_dir/$rel"
    done < <(find "$staging" -type f -name '*.json' -print0)
    log "done"
  '';
in
{
  inherit script;
  app = {
    type = "app";
    program = toString script;
  };
}
