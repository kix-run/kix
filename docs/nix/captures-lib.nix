# Shared building blocks for the docs captures pipeline.
#
# Both the offline driver (`captures-offline.nix`, runs in a Nix sandbox)
# and the live driver (`captures-live.nix`, runs as a host shell script
# against kind) compose the helpers in here. The library is intentionally
# free of pipeline-level state — it returns shell snippets parameterised
# by group/step plus a small set of runtime expectations the caller
# documents below.

{
  pkgs,
  lib,
  kix,
  kixExamples,
  # Store path of the kixpkgs flake source. Forwarded to every kix
  # invocation as `--override-input kixpkgs path:<store>` so the
  # workspace's eval resolves against a known, already-realised
  # source instead of re-fetching via github. The workspace's
  # flake.lock for nixpkgs is left untouched — both drivers run
  # host-side with network access, so the standard fetcher just
  # works for everything else.
  kixpkgsSrc,
}:

let
  transforms = import ./output-transforms.nix { inherit lib; };

  mkSedPipeline =
    names:
    if names == [ ] then
      "cat"
    else
      lib.concatMapStringsSep " | " (
        name: "sed -E ${lib.escapeShellArg transforms.programs.${name}}"
      ) names;

  displayPipeline = mkSedPipeline transforms.displayTransforms;
  baseDriftPipeline = mkSedPipeline transforms.driftTransforms;

  # `LC_ALL=C sort -u` pins to byte-order sort (host locale doesn't
  # leak into drift comparisons) and collapses duplicate lines. The
  # dedupe is load-bearing for `kix graph --format tree`, where the
  # same resource gets rendered N times (once per parent edge in the
  # underlying DAG) and N moves around with traversal order. For
  # captures whose output is unique line-by-line (YAML manifests,
  # tables, etc.) `-u` is a no-op.
  driftPipelineFor =
    step:
    if (step.sortLines or true) then "${baseDriftPipeline} | LC_ALL=C sort -u" else baseDriftPipeline;

  # Display-only join: produces the human-readable `❱` prompt string
  # for the rendered docs. Not shell-safe — manifest args never
  # contain single quotes, so the naive wrap-in-quotes-if-space is
  # fine for this purpose. Don't reuse for actual shell invocation.
  mkDisplayCommand =
    run: lib.concatStringsSep " " (map (arg: if lib.hasInfix " " arg then "'${arg}'" else arg) run);

  # Mutate step → shell. Runs `oldString → newString` literal
  # substitution against `$workspace/<file>`. Three preflight checks
  # short-circuit the whole run rather than producing partial sidecars:
  # missing file, no match, multi-match (oldString isn't unique).
  mutateShell =
    m:
    let
      fileQ = lib.escapeShellArg m.file;
      oldQ = lib.escapeShellArg m.oldString;
      newQ = lib.escapeShellArg m.newString;
    in
    ''
            __mutate_file=${fileQ}
            __mutate_target="$workspace/$__mutate_file"
            __mutate_old=${oldQ}
            __mutate_new=${newQ}

            if [ ! -f "$__mutate_target" ]; then
              echo "captures.mutate: file not found: $__mutate_file" >&2
              exit 2
            fi
            __mutate_count=$(grep -F -c -- "$__mutate_old" "$__mutate_target" || true)
            if [ "$__mutate_count" -eq 0 ]; then
              echo "captures.mutate: oldString not found in $__mutate_file" >&2
              exit 2
            fi
            if [ "$__mutate_count" -ne 1 ]; then
              echo "captures.mutate: oldString matched $__mutate_count times in $__mutate_file (must be unique)" >&2
              exit 2
            fi
            ${pkgs.python3}/bin/python3 -c '
      import sys
      path, old, new = sys.argv[1:]
      with open(path, "r") as f:
          content = f.read()
      with open(path, "w") as f:
          f.write(content.replace(old, new, 1))
      ' "$__mutate_target" "$__mutate_old" "$__mutate_new"
    '';

  # Workspace setup shell. Caller is expected to have:
  #   $workspace — empty writable directory the workspace will live in.
  # After this snippet, $workspace contains kix-examples + (optional)
  # overlay + applied setup mutations. The workspace's `flake.nix` and
  # `flake.lock` are untouched; kix-side `--override-input kixpkgs
  # path:<store>` (see `kixOverrideArgs` below) handles the repoint.
  workspaceSetupShell =
    group:
    let
      overlayCp =
        if group ? overlay then
          # Re-chmod after the overlay copy: overlay files come from
          # /nix/store read-only, and the kix-examples copy's earlier
          # chmod doesn't reach them.
          ''
            cp -r --no-preserve=mode ${group.overlay}/. "$workspace/"
            chmod -R u+w "$workspace"
          ''
        else
          "";
      setupSteps = group.setup or [ ];
      mutateBlocks = lib.concatMapStringsSep "\n" (
        s:
        if s ? mutate then
          mutateShell s.mutate
        else
          throw "captures.setup: only `mutate` steps are allowed in setup; got: ${builtins.toJSON s}"
      ) setupSteps;
    in
    ''
      cp -r --no-preserve=mode ${kixExamples}/. "$workspace/"
      chmod -R u+w "$workspace"
      ${overlayCp}
      ${mutateBlocks}
    '';

  # Capture step → shell. Parameterised by:
  #   invocation — shell string that invokes the binary with whatever
  #     auto-flags the driver wants (PTY wrap, --context, --flake, etc.)
  #   generator  — "offline" or "live"; baked into the sidecar JSON.
  # Caller is expected to have on PATH or pinned: jq, sed, python3.
  # Caller is expected to have set: $workspace, $stagingDir.
  captureShell =
    {
      group,
      step,
      invocation,
      generator,
    }:
    let
      restArgs = lib.tail step.run;
      id = "${group.group}/${step.capture}";
      displayCommand = mkDisplayCommand step.run;
      stepDriftPipeline = driftPipelineFor step;
      allowFailure = step.allowFailure or false;
      allowFailureGuard =
        if allowFailure then
          ""
        else
          ''
            if [ "$__exit_code" -ne 0 ]; then
              echo "captures.capture: command failed with exit $__exit_code: ${displayCommand}" >&2
              echo "--- stdout ---" >&2
              cat "$__stdout_raw" >&2
              echo "--- stderr ---" >&2
              cat "$__stderr_raw" >&2
              echo "(set allowFailure = true on this step to record the failure as a sidecar)" >&2
              exit 5
            fi
          '';
    in
    ''
      printf '  capturing %s :: %s\n' ${lib.escapeShellArg id} ${lib.escapeShellArg displayCommand}

      __stdout_raw=$(mktemp)
      __stderr_raw=$(mktemp)
      __stdout_display=$(mktemp)
      __stderr_display=$(mktemp)
      __stdout_drift=$(mktemp)
      __stderr_drift=$(mktemp)

      set +e
      ( cd "$workspace" && \
        ${invocation} ${lib.escapeShellArgs restArgs} \
      ) > "$__stdout_raw" 2> "$__stderr_raw"
      __exit_code=$?
      set -e

      ${allowFailureGuard}

      # Redact workspace path so per-run tempdir names don't leak into
      # the rendered docs.
      sed -i "s#$workspace#kix-examples#g" "$__stdout_raw" "$__stderr_raw"

      <"$__stdout_raw" ${displayPipeline} > "$__stdout_display"
      <"$__stderr_raw" ${displayPipeline} > "$__stderr_display"
      <"$__stdout_raw" ${stepDriftPipeline} > "$__stdout_drift"
      <"$__stderr_raw" ${stepDriftPipeline} > "$__stderr_drift"

      mkdir -p "$stagingDir/${group.group}"
      jq -n \
        --arg id ${lib.escapeShellArg id} \
        --arg group ${lib.escapeShellArg group.group} \
        --arg page ${lib.escapeShellArg group.page} \
        --arg command ${lib.escapeShellArg displayCommand} \
        --arg cwd ${lib.escapeShellArg group.cwd} \
        --arg generator ${lib.escapeShellArg generator} \
        --argjson exitCode "$__exit_code" \
        --rawfile stdout "$__stdout_display" \
        --rawfile stderr "$__stderr_display" \
        --rawfile stdoutDrift "$__stdout_drift" \
        --rawfile stderrDrift "$__stderr_drift" \
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
        }' > "$stagingDir/${group.group}/${step.capture}.json"

      rm -f "$__stdout_raw" "$__stderr_raw" \
            "$__stdout_display" "$__stderr_display" \
            "$__stdout_drift" "$__stderr_drift"
    '';

  # Step dispatch. A step is either `mutate` (applied in-place) or
  # `capture` (runs a command and writes a sidecar). Drivers loop over
  # steps in declaration order and let the dispatch fall out.
  mkStepShell =
    {
      group,
      step,
      invocationFor,
      generator,
    }:
    if step ? mutate then
      mutateShell step.mutate
    else if step ? capture then
      captureShell {
        inherit group step generator;
        invocation = invocationFor step;
      }
    else
      throw "captures: step must have either `mutate` or `capture`; got: ${builtins.toJSON step}";

  manifest = import ./captures.nix;

  # Shared `--override-input` snippet drivers splice into their kix
  # invocation strings. Pins the workspace's `kixpkgs` input to the
  # in-store source so the eval kix triggers next never has to
  # re-fetch from github (and so the workspace's own flake.lock,
  # which still points at a different rev, is harmless).
  kixOverrideArgs = ''--override-input kixpkgs "path:${kixpkgsSrc}"'';
in
{
  inherit manifest;
  inherit
    mkDisplayCommand
    workspaceSetupShell
    mutateShell
    captureShell
    mkStepShell
    kixOverrideArgs
    ;
}
