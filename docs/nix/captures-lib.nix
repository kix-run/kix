# Shared building blocks for the docs captures pipeline.
#
# Both the offline driver (`captures-offline.nix`, runs in a Nix sandbox)
# and the live driver (`captures-live.nix`, runs as a host shell script
# against kind) compose the helpers in here. The library is
# free of pipeline-level state: it returns shell snippets parameterised
# by group/step plus a small set of runtime expectations the caller
# documents below.

{
  pkgs,
  lib,
  kix,
  kixExamples,
  # Store path of the kixpkgs flake source. Forwarded to every kix
  # invocation as `--override-input kix path:<store>` so the
  # workspace's eval resolves against a known, already-realised
  # source instead of re-fetching via github. The workspace's
  # flake.lock for nixpkgs is left untouched: both drivers run
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
  # dedupe is load-bearing for `kix graph -o tree`, where the
  # same resource gets rendered N times (once per parent edge in the
  # underlying DAG) and N moves around with traversal order. For
  # captures whose output is unique line-by-line (YAML manifests,
  # tables, etc.) `-u` is a no-op.
  driftPipelineFor =
    step:
    if (step.sortLines or true) then "${baseDriftPipeline} | LC_ALL=C sort -u" else baseDriftPipeline;

  # Display-only join: produces the human-readable `❱` prompt string
  # for the rendered docs. Not shell-safe: manifest args never
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
  #   $workspace: empty writable directory the workspace will live in.
  # After this snippet, $workspace contains kix-examples + (optional)
  # overlay + applied setup mutations. Kix-side
  # `--override-input kix path:<store>` (see `kixOverrideArgs` below)
  # points the workspace's Kix library at this checkout, and `flake.lock`
  # is left as it is.
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

  # Wrapper bin dir for `shell` steps. A shell step runs a command line
  # the reader would actually type, so `kix` (and `kubectl`, live) must
  # be on PATH already carrying the driver's auto-flags. We write a tiny
  # exec wrapper per binary into a temp dir and prepend it to PATH.
  #
  # `$workspace` is deliberately expanded when the wrapper is written,
  # not when it runs: the driver's invocation strings embed it.
  mkWrappers =
    invocationFor: names:
    map (name: {
      inherit name;
      invocation = invocationFor {
        run = [ name ];
        plain = true;
      };
    }) names;

  # The wrapper is named after the binary it wraps and lives on the front
  # of PATH, so it must not resolve that name through PATH itself or it
  # execs itself forever. Pinning PATH back to the driver's own value
  # (expanded here, at write time, before the prepend) keeps the lookup
  # pointed at the real binary.
  shellWrapperShell =
    wrappers:
    lib.concatMapStringsSep "\n" (w: ''
      cat > "$__shell_bin/${w.name}" <<WRAPPER
      #!/bin/sh
      PATH=$PATH
      exec ${w.invocation} "\$@"
      WRAPPER
      chmod +x "$__shell_bin/${w.name}"
    '') wrappers;

  # Every step runs under a wall-clock limit. A capture that stops making
  # progress is a bug worth a loud, named failure: without this the whole
  # regen just sits there and the maintainer has to guess which step.
  defaultStepTimeout = "600s";

  timeoutGuard = kind: label: exitVar: ''
    if [ "${exitVar}" -eq 124 ]; then
      echo "captures.${kind}: timed out after ${defaultStepTimeout}: ${label}" >&2
      echo "(raise it with \`timeout = \"900s\";\` on the step if the command is legitimately slow)" >&2
      exit 8
    fi
  '';

  # Every step reads from /dev/null. The live driver wraps commands in
  # `script` to get a pty, and `script` fails outright when the stdin it
  # inherits is a socket, which is what happens whenever the regen runs
  # from anything but an interactive shell.
  #
  # Capture step → shell. Parameterised by:
  #   invocation: shell string that invokes the binary with whatever
  #     auto-flags the driver wants (PTY wrap, --context, --flake, etc.)
  #   wrappers: [{ name; invocation; }] used only by `shell` steps, so
  #     the command line runs the driver-flagged binaries off PATH.
  #   generator: "offline" or "live"; baked into the sidecar JSON.
  # Caller is expected to have on PATH or pinned: jq, sed, python3.
  # Caller is expected to have set: $workspace, $stagingDir.
  captureShell =
    {
      group,
      step,
      invocation,
      generator,
      wrappers ? [ ],
    }:
    let
      isShellStep = step ? shell;
      restArgs = if isShellStep then [ ] else lib.tail step.run;
      id = "${group.group}/${step.capture}";
      stepTimeout = step.timeout or defaultStepTimeout;
      displayCommand = if isShellStep then step.shell else mkDisplayCommand step.run;
      # A shell step needs the wrapper bin dir on PATH; everything else
      # execs the driver's invocation directly with the step's args.
      runBlock =
        if isShellStep then
          ''
            __shell_bin=$(mktemp -d)
            ${shellWrapperShell wrappers}
            ( cd "$workspace" && PATH="$__shell_bin:$PATH" \
              timeout ${stepTimeout} bash -o pipefail -c ${lib.escapeShellArg step.shell} \
            ) < /dev/null > "$__stdout_raw" 2> "$__stderr_raw"
            __exit_code=$?
            rm -rf "$__shell_bin"
            ${timeoutGuard "capture" id "$__exit_code"}
          ''
        else
          ''
            ( cd "$workspace" && \
              timeout ${stepTimeout} ${invocation} ${lib.escapeShellArgs restArgs} \
            ) < /dev/null > "$__stdout_raw" 2> "$__stderr_raw"
            __exit_code=$?
            ${timeoutGuard "capture" id "$__exit_code"}
          '';
      stepDriftPipeline = driftPipelineFor step;
      allowFailure = step.allowFailure or false;
      stdoutFilter =
        if step ? stdoutJq then
          ''
            __stdout_filtered=$(mktemp)
            if ! jq ${lib.escapeShellArg step.stdoutJq} "$__stdout_raw" > "$__stdout_filtered"; then
              echo "captures.capture: stdoutJq failed for ${id}" >&2
              exit 6
            fi
            mv "$__stdout_filtered" "$__stdout_raw"
          ''
        else if step ? stdoutGrep then
          ''
            __stdout_filtered=$(mktemp)
            if ! grep -E -- ${lib.escapeShellArg step.stdoutGrep} "$__stdout_raw" \
              | sed -E 's/^[[:space:]]+//' > "$__stdout_filtered"; then
              echo "captures.capture: stdoutGrep matched no output for ${id}" >&2
              exit 6
            fi
            mv "$__stdout_filtered" "$__stdout_raw"
          ''
        else
          "";
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
      ${runBlock}
      set -e

      ${allowFailureGuard}
      ${stdoutFilter}

      # Redact workspace path so per-run tempdir names don't leak into
      # the rendered docs.
      #
      # Two spellings, longest first. `mktemp -d` hands back /var/... on
      # macOS while anything that resolves symlinks reports the same
      # directory as /private/var/..., so substituting only the short form
      # eats the tail of the long one and leaves `/privatekix-examples`
      # behind. That is invisible locally and fails the drift check on a
      # Linux runner, where the two spellings are identical.
      workspace_real=$(cd "$workspace" && pwd -P)
      sed -i "s#$workspace_real#kix-examples#g" "$__stdout_raw" "$__stderr_raw"
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
        --argjson outputExcerpt ${if step ? stdoutJq || step ? stdoutGrep then "true" else "false"} \
        --argjson exitCode "$__exit_code" \
        --argjson skipDriftCheck ${if (step.skipDriftCheck or false) then "true" else "false"} \
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
          outputExcerpt: $outputExcerpt,
          skipDriftCheck: $skipDriftCheck,
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

  # Prerequisite command that changes or verifies state for a later capture.
  # Its output is not stored, but a failure stops the group with diagnostics.
  prepareShell =
    {
      step,
      invocation,
      wrappers ? [ ],
    }:
    let
      # `prepare` is either an argv list or, when the command needs a
      # pipe or a redirect, a single shell string. A string prepare is
      # how a command whose output teaches nothing still gets executed
      # on every regen, so the docs cannot claim something the CLI no
      # longer does.
      isShellPrepare = builtins.isString step.run;
      restArgs = if isShellPrepare then [ ] else lib.tail step.run;
      displayCommand = if isShellPrepare then step.run else mkDisplayCommand step.run;
      stepTimeout = step.timeout or defaultStepTimeout;
      runBlock =
        if isShellPrepare then
          ''
            __shell_bin=$(mktemp -d)
            ${shellWrapperShell wrappers}
            ( cd "$workspace" && PATH="$__shell_bin:$PATH" \
              timeout ${stepTimeout} bash -o pipefail -c ${lib.escapeShellArg step.run} \
            ) < /dev/null > "$__prepare_stdout" 2> "$__prepare_stderr"
            __prepare_exit=$?
            rm -rf "$__shell_bin"
            ${timeoutGuard "prepare" displayCommand "$__prepare_exit"}
          ''
        else
          ''
            ( cd "$workspace" && \
              timeout ${stepTimeout} ${invocation} ${lib.escapeShellArgs restArgs} \
            ) < /dev/null > "$__prepare_stdout" 2> "$__prepare_stderr"
            __prepare_exit=$?
            ${timeoutGuard "prepare" displayCommand "$__prepare_exit"}
          '';
    in
    ''
      printf '  preparing :: %s\n' ${lib.escapeShellArg displayCommand}
      __prepare_stdout=$(mktemp)
      __prepare_stderr=$(mktemp)
      set +e
      ${runBlock}
      set -e
      if [ "$__prepare_exit" -ne 0 ]; then
        echo "captures.prepare: command failed with exit $__prepare_exit: ${displayCommand}" >&2
        echo "--- stdout ---" >&2
        cat "$__prepare_stdout" >&2
        echo "--- stderr ---" >&2
        cat "$__prepare_stderr" >&2
        exit 7
      fi
      rm -f "$__prepare_stdout" "$__prepare_stderr"
    '';

  # Step dispatch. A step is either `mutate` (applied in-place) or
  # `capture` (runs a command and writes a sidecar). Drivers loop over
  # steps in declaration order and let the dispatch fall out.
  #
  # `shellBinaries` names the binaries a driver is willing to put on
  # PATH for `shell` steps. Each becomes a wrapper carrying that
  # driver's auto-flags.
  mkStepShell =
    {
      group,
      step,
      invocationFor,
      generator,
      shellBinaries ? [ ],
    }:
    if step ? mutate then
      mutateShell step.mutate
    else if step ? prepare then
      let
        preparedStep = step // {
          run = step.prepare;
        };
      in
      prepareShell {
        step = preparedStep;
        invocation = if builtins.isString step.prepare then "" else invocationFor preparedStep;
        wrappers = mkWrappers invocationFor shellBinaries;
      }
    else if step ? capture then
      captureShell {
        inherit group step generator;
        invocation = if step ? shell then "" else invocationFor step;
        wrappers = mkWrappers invocationFor shellBinaries;
      }
    else
      throw "captures: step must have `mutate`, `prepare`, or `capture`; got: ${builtins.toJSON step}";

  manifest = import ./captures.nix;

  # Shared `--override-input` snippet drivers splice into their kix
  # invocation strings. Pins the workspace's `kix` input to the
  # in-store source so the eval kix triggers next never has to
  # re-fetch from github (and so the workspace's own flake.lock,
  # which still points at a different rev, is harmless). Kix treats an
  # overridden `kix` input as a development library: it runs itself and
  # compares no versions.
  kixOverrideArgs = ''--override-input kix "path:${kixpkgsSrc}"'';
in
{
  inherit manifest;
  inherit
    mkDisplayCommand
    workspaceSetupShell
    mutateShell
    prepareShell
    captureShell
    mkStepShell
    kixOverrideArgs
    ;
}
