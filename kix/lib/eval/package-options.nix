# Check a package's options against the option contract (eval/options.nix).
# Evaluate phase 1 at each availability level up to `meta.availability.max`
# so option defaults that depend on the level are checked at each one.
# Packages that do not accept `availability` are checked once.
{
  lib,
  kixlib,
  meta,
  callPackagePhase1,
  optionContractViolations,
}:

let
  availabilityLib = import ../core/availability.nix { inherit lib; };

  # Return the checked availability `levels` and deduplicated option contract
  # `violations`, annotated with the levels where each violation occurs.
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
  # Return the option contract violations for `package`.
  packageOptionViolations = args: (analyse args).violations;

  # Throw if `package` violates the option contract at any supported
  # availability level, or return null.
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
