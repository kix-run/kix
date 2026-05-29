# Offline driver for the captures pipeline.
#
# For each manifest group that has any `offline` steps, emit one
# `pkgs.runCommand` derivation that:
#
#   1. Builds a fresh writable workspace = kix-examples + overlay
#      + applied setup mutations.
#   2. Runs every offline step in declaration order against the
#      workspace, writing sidecars to `$out/<group>/<capture>.json`.
#
# Groups with no offline steps produce no derivation. The top-level
# output is the union of every per-group derivation, plus a
# `manifest.json` enumerating the captured sidecars.

{
  pkgs,
  lib,
  kix,
  kixExamples,
  kixpkgsSrc,
  nixpkgsSrc,
}:

let
  capturesLib = import ./captures-lib.nix {
    inherit
      pkgs
      lib
      kix
      kixExamples
      kixpkgsSrc
      nixpkgsSrc
      ;
  };

  inherit (capturesLib)
    manifest
    mkStepShell
    workspaceSetupShell
    mkDisplayCommand
    ;

  sanitizeName = lib.replaceStrings [ "/" ] [ "-" ];

  # Offline kix invocation: pinned-store kix binary, --no-cache so
  # nothing leaks between captures, --no-color so docs don't depend on
  # terminal width (ANSI for the live pipeline runs via PTY instead),
  # --flake $workspace so the cluster lookup respects setup mutations.
  invocationFor =
    step:
    let
      bin = lib.head step.run;
    in
    if bin == "kix" then
      ''${kix}/bin/kix --no-color --no-cache --flake "$workspace"''
    else
      throw "captures-offline: only `kix` is allowed offline (got `${bin}`); move kubectl/live commands to the live array";

  # Per-group derivation. The whole group runs in a single shell so
  # state (overlay, setup mutations, prior captures) carries across.
  mkGroupDrv =
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
    pkgs.runCommand "captures-offline-${sanitizeName group.group}"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.gnused
          pkgs.gnugrep
          pkgs.coreutils
          pkgs.python3
          pkgs.nix
        ];
        # Kix shells out to nix from inside this build. Two settings
        # cooperate to make that work under the strict-sandbox model
        # GitHub-hosted Linux runners use:
        #   - `recursive-nix` gives the build a usable NIX_REMOTE
        #     socket (in `$NIX_BUILD_TOP/.nix-socket`) that the daemon
        #     will accept for nested nix calls.
        #   - `__noChroot` lets the build read /nix/store paths kix
        #     transitively references during eval but that aren't in
        #     the declared input closure.
        # See https://github.com/NixOS/nix/issues/7297 for the
        # documented combination. On macOS the daemon ships with
        # `sandbox = false` so neither is needed (and recursive-nix
        # is not advertised as a system feature there) — making the
        # requirement Linux-only.
        requiredSystemFeatures = lib.optional pkgs.stdenv.isLinux "recursive-nix";
        __noChroot = true;
      }
      ''
        set -euo pipefail

        # Let kix's embedded nix use the daemon. With
        # requiredSystemFeatures = [ "recursive-nix" ] the daemon
        # exposes a NIX_REMOTE socket that the build can use, so
        # nested nix calls succeed even from inside the sandbox.
        export HOME="$TMPDIR/home"
        export XDG_CACHE_HOME="$TMPDIR/cache"
        export NO_COLOR=1
        mkdir -p "$HOME" "$XDG_CACHE_HOME"

        # Deterministic per-build path; $TMPDIR is already a fresh
        # per-build dir, so no `mktemp` is needed.
        workspace="$TMPDIR/workspace"
        mkdir -p "$workspace"
        stagingDir="$out"
        mkdir -p "$stagingDir"

        ${workspaceSetupShell group}

        ${stepShellBlocks}
      '';

  groupsWithOffline = builtins.filter (g: (g.offline or [ ]) != [ ]) manifest;

  groupDrvs = map (group: {
    inherit group;
    drv = mkGroupDrv group;
  }) groupsWithOffline;

  # Manifest the docs/components can introspect: id, group, page, cwd,
  # displayCommand, generated path. Carried for parity with the prior
  # offline-only manifest.json that the test harness reads.
  manifestEntries = lib.concatMap (
    group:
    map (step: {
      id = "${group.group}/${step.capture}";
      inherit (group) group page cwd;
      displayCommand = mkDisplayCommand step.run;
      file = "${group.group}/${step.capture}.json";
    }) (builtins.filter (s: s ? capture) (group.offline or [ ]))
  ) manifest;

  manifestFile = builtins.toFile "captures-offline-manifest.json" (
    builtins.toJSON { commands = manifestEntries; }
  );

  copyGroupsCmd = lib.concatMapStringsSep "\n" (
    g: ''cp -r --no-preserve=mode ${g.drv}/. "$out/"''
  ) groupDrvs;
in
# Local: pure file-shuffling, not worth a binary-cache round-trip.
pkgs.runCommandLocal "captures-offline" { } ''
  mkdir -p "$out"
  ${copyGroupsCmd}
  cp ${manifestFile} "$out/manifest.json"
''
