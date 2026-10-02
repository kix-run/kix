# The option contract (eval/options.nix) over a package rather than an
# options set. Phase 1 is called the way instance evaluation calls it: at
# each availability level the package can run at (every level up to its
# `meta.availability.max`) with the `kix` an instance at that level
# receives, so an option default that depends on the level is checked at
# each one. A package that does not take `availability` is checked once.
{
  lib,
  kixlib,
  meta,
  callPackagePhase1,
  optionContractViolations,
}:

let
  availabilityLib = import ../core/availability.nix { inherit lib; };

  # `levels`, the availability levels checked, and `violations`, one entry
  # per violation as optionContractViolations returns them with `levels`
  # naming the levels it occurs at. `scope` is the phase-1 scope; a default
  # that reads `scope.instanceName` sees its value.
  analyse =
    {
      package,
      who ? "the package",
      scope ? {
        instanceName = "check";
        namespaceName = "check";
      },
    }:
    let
      ceiling = availabilityLib.ceilingOfMeta {
        value =
          (meta.peekPackageMeta {
            inherit package kixlib;
          }).availability or null;
        where = who;
      };
      checkedCeiling =
        if ceiling == null then
          null
        else
          availabilityLib.checkCeiling {
            value = ceiling;
            where = who;
            what = "meta.availability.max";
          };
      takesLevel = builtins.isFunction package && (builtins.functionArgs package) ? availability;
      levels =
        if !takesLevel then
          [ "none" ]
        else if checkedCeiling == null then
          availabilityLib.levels
        else
          builtins.filter (
            l: availabilityLib.rank l <= availabilityLib.rank checkedCeiling
          ) availabilityLib.levels;
      kix = kixlib // {
        availability =
          kixlib.availability
          // availabilityLib.underCeiling {
            ceiling = checkedCeiling;
            where = who;
          };
      };
      at =
        level:
        map (v: v // { inherit level; }) (optionContractViolations {
          options =
            (callPackagePhase1 {
              inherit package scope kix;
              availability = level;
            }).options or { };
        });
      byMessage = builtins.groupBy (v: v.message) (builtins.concatMap at levels);
    in
    {
      inherit levels;
      violations = lib.mapAttrsToList (
        _: vs:
        removeAttrs (builtins.head vs) [ "level" ]
        // {
          levels = map (v: v.level) vs;
        }
      ) byMessage;
    };
in
{
  # The violations of `analyse`, for a caller that reports them itself.
  packageOptionViolations = args: (analyse args).violations;

  # Throws when the package breaks the option contract at any level, with
  # one line per violation; a violation that does not occur at every level
  # names the levels it occurs at. Returns null otherwise.
  checkPackageOptions =
    args@{ package, ... }:
    let
      who = args.who or "the package";
      inherit (analyse args) levels violations;
      levelNote =
        v:
        lib.optionalString (builtins.length v.levels < builtins.length levels)
          " (at availability ${lib.concatMapStringsSep ", " (l: "\"${l}\"") v.levels})";
    in
    if violations == [ ] then
      null
    else
      throw (
        "the options of ${who} break the option contract (docs: reference/package-schema/options, \"Option contract\"):\n"
        + lib.concatMapStringsSep "\n" (v: "  - ${v.message}${levelNote v}") violations
      );
}
