# Build `kix.contracts` from the contract files beside this file.
#
# A contract says what a package publishes on `root.out` for other packages
# to read. `stable/` holds contracts that break only in a minor release.
# `experimental/` holds contracts that may break in any release. A package
# reaches them as `kix.contracts.<name>` and
# `kix.contracts.experimental.<name>`, where the name is the file's name.
#
# Each file is a function that returns the result of `mkContract`
# (`kix/lib/vocab/contract.nix`), so every contract has the same parts.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  builder = import ../lib/vocab/contract.nix { inherit lib; };
  compose = import ../lib/vocab/compose.nix { inherit lib; };
  moved = import ./moved.nix { inherit lib; };
  errors = import ../lib/core/error.nix { inherit lib; };

  load =
    level:
    levels.list {
      dir = ./. + "/${level}";
      keep = file: type: type == "regular" && lib.hasSuffix ".nix" file;
      load =
        path: file:
        let
          name = lib.removeSuffix ".nix" file;
        in
        lib.nameValuePair name (
          moved name
          // import path {
            inherit lib compose;
            inherit (builder) credentialsField;
            mkContract =
              args:
              builder.mkContract (
                args
                // {
                  here = "kix/contracts/${level}/${file}";
                  path = "contracts.${lib.optionalString (level == "experimental") "experimental."}${name}";
                }
              );
          }
        );
    };
in
levels.merge {
  prefix = "kix.contracts";
  stable = load "stable";
  experimental = load "experimental";
  # Contracts that were stable before Kix 0.10. Remove these names once the
  # refusals have been in a minor release.
  demoted = _: errors.fail;
  demotedNames = [
    "oidcProvider"
    "otlpEndpoint"
  ];
  demotedId = "K0549";
}
