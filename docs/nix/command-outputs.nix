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

  sanitizeName = lib.replaceStrings [ "/" ] [ "-" ];

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
            ${lib.escapeShellArgs ([ "${kix}/bin/kix" ] ++ fullArgs)} > stdout 2> stderr
            code=$?

            sed -i 's#${kixExamples}#kix-examples#g' stdout stderr

            if [ "$code" -ne 0 ] && [ "${if allowFailure then "1" else "0"}" != "1" ]; then
              cat stdout
              cat stderr >&2
              exit "$code"
            fi

            jq -n \
              --arg id ${lib.escapeShellArg command.id} \
              --arg group ${lib.escapeShellArg command.group} \
              --arg page ${lib.escapeShellArg command.page} \
              --arg command ${lib.escapeShellArg command.displayCommand} \
              --arg cwd ${lib.escapeShellArg command.cwd} \
              --argjson exitCode "$code" \
              --rawfile stdout stdout \
              --rawfile stderr stderr \
              '{
                id: $id,
                group: $group,
                page: $page,
                command: $command,
                cwd: $cwd,
                exitCode: $exitCode,
                stdout: $stdout,
                stderr: $stderr
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
