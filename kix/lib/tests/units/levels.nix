# Tests for the stable and experimental levels (kix/lib/core/levels.nix):
# the merged set a cluster or a package reads, the error for a name that
# has only a stable entry, and the one shape every contract in
# kix/contracts has.

{
  lib,
  kixlib,
  ...
}:

let
  levels = import ../../core/levels.nix { inherit lib; };
  packages = import ../../../packages { inherit lib; };
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  contracts = kixlib.contracts;

  fails = v: !(builtins.tryEval v).success;

  merged = levels.merge {
    prefix = "things";
    stable = {
      a = 1;
      b = 2;
    };
    experimental = {
      b = 20;
      c = 30;
    };
  };

  contractKeys = [
    "alias"
    "assertions"
    "check"
    "fields"
    "helpers"
    "name"
    "options"
    "problems"
    "require"
  ];
  # The names refused since 0.10 (kix/contracts/moved.nix) sit beside a
  # contract's parts until they are removed.
  moved = import ../../../contracts/moved.nix { inherit lib; };
  partsOf = name: contract: removeAttrs contract (builtins.attrNames (moved name));
in
{
  # Stable entries are read at the top and under `stable`, and an
  # experimental entry only under `experimental`, where it may share a
  # stable entry's name.
  levels-merge-spellings =
    (
      merged.a == 1
      && merged.b == 2
      &&
        merged.stable == {
          a = 1;
          b = 2;
        }
      && merged.experimental.b == 20
      && merged.experimental.c == 30
      && !(merged ? c)
    )
    || throw "levels merge: ${builtins.toJSON (builtins.attrNames merged)}";

  # An experimental name with only a stable entry is refused.
  levels-graduated-name-is-refused =
    fails merged.experimental.a || throw "levels: experimental.a evaluated";

  # `stable` and `experimental` cannot be entries.
  levels-reserved-names =
    fails (
      levels.merge {
        prefix = "things";
        stable.experimental = 1;
        experimental = { };
      }
    )
    || throw "levels: an entry named experimental was accepted";

  # Every stable package is read by its short name, and `packages.stable`
  # holds the packages and nothing else.
  levels-packages-set =
    (
      builtins.attrNames packages.stable == builtins.attrNames packagesByLevel.stable
      && lib.all (name: packages ? ${name}) (builtins.attrNames packagesByLevel.stable)
      &&
        builtins.attrNames packages.experimental == lib.unique (
          builtins.sort builtins.lessThan (
            builtins.attrNames packagesByLevel.stable ++ builtins.attrNames packagesByLevel.experimental
          )
        )
    )
    || throw "levels: packages set does not match the two folders";

  # Every contract file returns the parts `mkContract` builds and no others.
  levels-contract-shape =
    let
      wrong = lib.filterAttrs (
        name: contract: builtins.attrNames (partsOf name contract) != contractKeys
      ) contracts.stable;
    in
    wrong == { }
    || throw "contracts with other parts than ${builtins.toJSON contractKeys}: ${
      builtins.toJSON (lib.mapAttrs (name: c: builtins.attrNames (partsOf name c)) wrong)
    }";

  # A helper's old name is refused, and its new name works.
  levels-moved-helper-is-refused =
    (fails contracts.redis.usesSentinel && builtins.isFunction contracts.redis.helpers.usesSentinel)
    || throw "contracts: redis.usesSentinel evaluated";
}
