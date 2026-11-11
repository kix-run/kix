# Build the sets that hold stable and experimental packages and contracts.
{ lib }:
rec {
  names = [
    "stable"
    "experimental"
  ];

  # Return the entries of `dir` that `keep name type` accepts, as an
  # attribute set from entry name to `load path name`.
  list =
    {
      dir,
      keep,
      load,
    }:
    lib.mapAttrs' (file: _: load (dir + "/${file}") file) (lib.filterAttrs keep (builtins.readDir dir));

  # Merge the two levels into the set a cluster or a package reads. Stable
  # entries sit at the top and again under `stable`, which holds nothing
  # else. Under `experimental`, a name that has only a stable entry fails
  # with an error that gives the stable spelling, which is what a user sees
  # after an entry graduates. Code that walks the experimental entries reads
  # the unmerged set, because walking the merged one meets those errors.
  merge =
    {
      # How a user spells the set, such as `packages` or `kix.contracts`.
      prefix,
      stable,
      experimental,
      # Return the value that stands at the top for an experimental entry
      # that used to be stable, given the error message for its old name.
      # Null leaves those names out.
      demoted ? null,
      # Names of experimental entries that used to be stable, and the change
      # record id their error starts with.
      demotedNames ? [ ],
      demotedId ? null,
    }:
    let
      reserved = lib.filter (name: stable ? ${name} || experimental ? ${name}) names;
      graduated = lib.mapAttrs (
        name: _: throw "`${prefix}.experimental.${name}` is stable now. Write `${prefix}.${name}`."
      ) (removeAttrs stable (builtins.attrNames experimental));
      unknownDemoted = lib.filter (name: !(experimental ? ${name}) || stable ? ${name}) demotedNames;
      wasStable = lib.genAttrs demotedNames (
        name:
        demoted "${demotedId} `${prefix}.${name}` is experimental now, so it may change in any release. Write `${prefix}.experimental.${name}`."
      );
    in
    assert lib.assertMsg (reserved == [ ])
      "${prefix}: ${lib.concatStringsSep " and " reserved} cannot be the name of an entry, because `${prefix}.stable` and `${prefix}.experimental` hold the two levels.";
    assert lib.assertMsg (unknownDemoted == [ ])
      "${prefix}: ${lib.concatStringsSep ", " unknownDemoted} is listed as moved to experimental, but it is not an experimental entry, or it is also a stable one. Remove it from the list.";
    lib.optionalAttrs (demoted != null) wasStable
    // stable
    // {
      inherit stable;
      experimental = graduated // experimental;
    };
}
