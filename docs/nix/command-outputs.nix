# Command output generation: run selected, non-live `kix` commands against
# checked-in examples and emit JSON sidecars for MDX pages.
#
# Keep the manifest grouped by docs page or example so it remains readable as
# the number of captured commands grows.

{
  pkgs,
  lib,
  kix,
  kixExamples,
}:

let
  groups = import ./command-outputs-manifest.nix;
  transforms = import ./output-transforms.nix { inherit lib; };

  sanitizeName = lib.replaceStrings [ "/" ] [ "-" ];

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
  # a `sort` stage so non-deterministic line ordering doesn't surface as
  # drift. Opt out for output where line order carries meaning (tree views,
  # ordered plans).
  driftPipelineFor =
    entry: if (entry.sortLines or true) then "${baseDriftPipeline} | sort" else baseDriftPipeline;

  mkDisplayCommand =
    command:
    lib.concatStringsSep " " (
      [ "kix" ] ++ (map (arg: if lib.hasInfix " " arg then "'${arg}'" else arg) command.args)
    );

  commandEntries = lib.concatMap (
    group:
    map (
      command:
      command
      // {
        inherit (group) group page cwd;
        id = "${group.group}/${command.name}";
        displayCommand = command.displayCommand or (mkDisplayCommand command);
      }
    ) group.commands
  ) groups;

  mkCommandOutput =
    command:
    let
      allowFailure = command.allowFailure or false;
      outputName = sanitizeName command.id;
      fullArgs = [
        "--no-color"
        "--no-cache"
        "--flake"
        "${kixExamples}"
      ]
      ++ command.args;
      driftPipeline = driftPipelineFor command;
    in
    {
      path = "${command.id}.json";
      drv =
        pkgs.runCommand "kix-doc-command-output-${outputName}"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.gnused
              pkgs.nix
            ];
          }
          ''
            set +e

            export HOME="$TMPDIR/home"
            export XDG_CACHE_HOME="$TMPDIR/cache"
            export NO_COLOR=1
            mkdir -p "$HOME" "$XDG_CACHE_HOME"

            cd "$TMPDIR"
            ${lib.escapeShellArgs ([ "${kix}/bin/kix" ] ++ fullArgs)} > stdout_raw 2> stderr_raw
            code=$?

            sed -i 's#${kixExamples}#kix-examples#g' stdout_raw stderr_raw

            if [ "$code" -ne 0 ] && [ "${if allowFailure then "1" else "0"}" != "1" ]; then
              cat stdout_raw
              cat stderr_raw >&2
              exit "$code"
            fi

            <stdout_raw ${displayPipeline} > stdout_display
            <stderr_raw ${displayPipeline} > stderr_display
            <stdout_raw ${driftPipeline}   > stdout_drift
            <stderr_raw ${driftPipeline}   > stderr_drift

            jq -n \
              --arg id ${lib.escapeShellArg command.id} \
              --arg group ${lib.escapeShellArg command.group} \
              --arg page ${lib.escapeShellArg command.page} \
              --arg command ${lib.escapeShellArg command.displayCommand} \
              --arg cwd ${lib.escapeShellArg command.cwd} \
              --argjson exitCode "$code" \
              --rawfile stdout stdout_display \
              --rawfile stderr stderr_display \
              --rawfile stdoutDrift stdout_drift \
              --rawfile stderrDrift stderr_drift \
              '{
                id: $id,
                group: $group,
                page: $page,
                cwd: $cwd,
                generator: "offline",
                commands: [{
                  command: $command,
                  stdout: $stdout,
                  stderr: $stderr,
                  stdoutDrift: $stdoutDrift,
                  stderrDrift: $stderrDrift,
                  exitCode: $exitCode
                }]
              }' > "$out"
          '';
    };

  outputs = map mkCommandOutput commandEntries;
  manifest = {
    commands = map (command: {
      inherit (command)
        id
        group
        page
        cwd
        displayCommand
        ;
      file = "${command.id}.json";
    }) commandEntries;
  };
  manifestFile = builtins.toFile "command-output-manifest.json" (builtins.toJSON manifest);

  copyCommands = lib.concatMapStringsSep "\n" (output: ''
    mkdir -p "$out/$(dirname ${lib.escapeShellArg output.path})"
    cp ${output.drv} "$out/${output.path}"
  '') outputs;
in
pkgs.runCommand "kix-doc-command-outputs" { } ''
  mkdir -p "$out"
  ${copyCommands}
  cp ${manifestFile} "$out/manifest.json"
''
