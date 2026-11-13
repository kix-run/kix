# Availability levels (`none`, `pod`, `node`, and `zone`) and helpers exposed
# to packages as `kix.availability`.
#
#   none  downtime on any failure or update is accepted
#   pod   a pod crash or a rolling update causes no downtime
#   node  the loss of one node causes no downtime      (needs multiNode)
#   zone  the loss of one zone causes no downtime      (needs two or more zones)
#
# The same levels serve as ceilings via `meta.availability.max` on a package
# or `availability.max` on a workload builder call. A `none` ceiling restricts
# a Deployment or StatefulSet to at most one replica.
{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
  levels = [
    "none"
    "pod"
    "node"
    "zone"
  ];

  rank =
    level:
    let
      i = lib.lists.findFirstIndex (l: l == level) null levels;
    in
    if i == null then
      fail "availability: '${toString level}' is not one of ${lib.concatStringsSep ", " levels}"
    else
      i;

  # Validate that `value` is a known availability level, or fail with an error
  # pointing at `where` and `what`.
  checkCeiling =
    {
      value,
      where,
      what,
    }:
    let
      shown = if builtins.isString value then "\"${value}\"" else "a ${builtins.typeOf value}";
    in
    if builtins.isString value && builtins.elem value levels then
      value
    else
      fail {
        instance = where;
        message = "${what} = ${shown} is not an availability level.";
        fix = "Use one of ${lib.concatMapStringsSep ", " (l: "\"${l}\"") levels}.";
      };

  # Return true when `level` is at least `min`.
  atLeast = min: level: rank level >= rank min;

  # Select the entry for `level` from `table`, requiring every availability
  # level to be present.
  pick = level: table: builtins.seq (checkPickTable table) table.${level};

  checkPickTable =
    table:
    let
      missing = builtins.filter (l: !(table ? ${l})) levels;
    in
    missing == [ ]
    || fail {
      message = "kix.availability.pick: table is missing ${lib.concatStringsSep ", " missing}.";
      fix = "Give an entry for every level: ${lib.concatStringsSep ", " levels}.";
    };

  # Extract `max` from a package's `meta.availability` attrset, or return null.
  ceilingOfMeta =
    { value, where }:
    let
      unknown = builtins.attrNames (removeAttrs value [ "max" ]);
    in
    if value == null then
      null
    else if !builtins.isAttrs value then
      fail {
        instance = where;
        message = "meta.availability is a ${builtins.typeOf value}.";
        fix = "Write meta.availability.max = \"<level>\".";
      }
    else if unknown != [ ] then
      fail {
        instance = where;
        message = "meta.availability has unknown key(s) ${lib.concatStringsSep ", " unknown}. The only key is max.";
      }
    else
      value.max or null;

  # Return `{ pick, atLeast }` scoped to `ceiling` (`meta.availability.max`).
  # Fail when a package tests `atLeast` for a level above its own ceiling.
  underCeiling =
    { ceiling, where }:
    if ceiling == null then
      { inherit pick atLeast; }
    else
      {
        inherit pick;
        atLeast =
          min: level:
          if rank min > rank ceiling then
            fail {
              instance = where;
              message = "kix.availability.atLeast \"${min}\": meta.availability.max is \"${ceiling}\", so this test is always false.";
              fix = "Put the ceiling on the builder calls of the workloads that cannot reach \"${min}\", or remove the test.";
            }
          else
            atLeast min level;
      };

  # Return `{ level, certain }` for the highest availability level supported by
  # `capabilities`. `certain` is false when the deciding capabilities are null.
  substrate =
    capabilities:
    let
      multiNode = capabilities.multiNode or null;
      zones = capabilities.availabilityZones or null;
    in
    if multiNode == false then
      {
        level = "none";
        certain = true;
      }
    else if zones != null && builtins.length zones > 1 then
      {
        level = "zone";
        certain = multiNode != null;
      }
    else
      {
        level = "node";
        certain = multiNode != null && zones != null;
      };

  # Build `topologySpreadConstraints` for pods at `level` selected by
  # `selector` (`matchLabels`). Returns one constraint per failure-domain key
  # in `topology`, or `[ ]` on a single-node cluster. Packages use this for
  # operator-managed operands whose CRs accept pod topology spread constraints.
  spreadConstraints =
    {
      level,
      selector,
      topology,
    }:
    let
      whenUnsatisfiable =
        key:
        if level == "zone" && key == topology.zoneKey then
          "DoNotSchedule"
        else if level == "node" && key == topology.hostKey then
          "DoNotSchedule"
        else
          "ScheduleAnyway";
    in
    # `nodeTaintsPolicy = "Honor"` excludes tainted control-plane nodes from
    # skew counts so a hard hostname constraint does not block worker pods.
    map (key: {
      topologyKey = key;
      maxSkew = 1;
      whenUnsatisfiable = whenUnsatisfiable key;
      nodeTaintsPolicy = "Honor";
      labelSelector.matchLabels = selector;
    }) topology.failureDomainKeys;

  # Resolve an instance's effective availability level from `instanceOverride`
  # or `clusterDefault`, cap it at `ceiling` (`meta.availability.max`), and
  # validate it against the cluster's capabilities.
  resolve =
    {
      capabilities,
      clusterDefault,
      instanceOverride ? null,
      ceiling ? null,
      where,
    }:
    let
      packageCeiling =
        if ceiling == null then
          null
        else
          checkCeiling {
            value = ceiling;
            inherit where;
            what = "meta.availability.max";
          };
      sub = substrate capabilities;
      requested = if instanceOverride != null then instanceOverride else clusterDefault;
      requestedFrom =
        if instanceOverride != null then
          "instances.${where}.availability"
        else
          "cluster.availability.default";
      overSubstrate = rank requested > rank sub.level;
      capped = packageCeiling != null && rank requested > rank packageCeiling;
      level = if capped then packageCeiling else requested;
      needs =
        if requested == "zone" then
          "two or more cluster.capabilities.availabilityZones"
        else
          "cluster.capabilities.multiNode = true";
      _substrateCheck =
        if overSubstrate && sub.certain then
          fail {
            message = "${where}: ${requestedFrom} = \"${requested}\", which requires ${needs}, and this cluster's capabilities offer at most \"${sub.level}\".";
            fix =
              "Lower ${requestedFrom} to \"${sub.level}\" (or lower)."
              + "\nIf this cluster has the required nodes or zones, declare ${needs} in your cluster definition.";
          }
        else
          null;
    in
    builtins.seq _substrateCheck {
      inherit
        level
        requested
        capped
        ;
      ceiling = packageCeiling;
      substrate = sub;
      warnings =
        lib.optional (overSubstrate && !sub.certain) (
          "[${where}] ${requestedFrom} = \"${requested}\" needs ${needs}, which this cluster has not declared. "
          + "Set the capability to match your environment, or lower the availability level. Kix cannot verify the requested availability without this information."
        )
        ++ lib.optional capped (
          "[${where}] availability \"${requested}\" was requested but the package declares "
          + "meta.availability.max = \"${packageCeiling}\", so it runs at \"${packageCeiling}\". "
          + "This instance does not meet the requested availability level."
        );
    };
in
{
  inherit
    levels
    rank
    checkCeiling
    ceilingOfMeta
    underCeiling
    atLeast
    pick
    substrate
    spreadConstraints
    resolve
    ;
}
