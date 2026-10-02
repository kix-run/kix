# The availability level: one word for how much
# failure a workload must survive, and the arithmetic every consumer of it
# shares. Design: v2_discussions/archive/145_availability_level.md.
#
#   none  downtime on any failure or update is accepted
#   pod   a pod crash or a rolling update causes no downtime
#   node  the loss of one node causes no downtime      (needs multiNode)
#   zone  the loss of one zone causes no downtime      (needs two or more zones)
#
# The same words serve as a ceiling, the highest level a workload supports
# (`meta.availability.max` for every workload of a package, `availability.max`
# on one builder call). The ceiling `none` means the workload runs one pod at
# a time; the availability plugin refuses a Deployment or StatefulSet above
# one replica under it.
#
# Pure: no module system, no scope. `resolve` is called once per instance
# by eval/instance.nix; `pick`, `atLeast` and `spreadConstraints` are what
# packages see as `kix.availability`, with `atLeast` replaced by its
# `underCeiling` form for an instance whose package declares
# meta.availability.max.
{ lib }:

let
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
      throw "availability: '${toString level}' is not one of ${lib.concatStringsSep ", " levels}"
    else
      i;

  # A ceiling (`meta.availability.max`, or `availability.max` on a builder
  # call) must be a level. `where` is "ns/inst" and `what` names the field,
  # so the message points at the declaration rather than at `rank`.
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
      throw "[${where}] ${what} = ${shown} is not an availability level. Use one of ${
        lib.concatMapStringsSep ", " (l: "\"${l}\"") levels
      }.";

  # atLeast "node" level: true for node and zone.
  atLeast = min: level: rank level >= rank min;

  # pick level { none = 1; pod = 2; node = 2; zone = 3; }. Every level must
  # be present so a package's mapping is complete by construction.
  pick = level: table: builtins.seq (checkPickTable table) table.${level};

  # true when `table` has every level; throws otherwise.
  checkPickTable =
    table:
    let
      missing = builtins.filter (l: !(table ? ${l})) levels;
    in
    missing == [ ]
    || throw "kix.availability.pick: table is missing ${lib.concatStringsSep ", " missing} (need every level: ${lib.concatStringsSep ", " levels})";

  # A package's `meta.availability`: null, or an attrset whose only key is
  # `max`. Returns `max` (checked later by `resolve`) or null.
  ceilingOfMeta =
    { value, where }:
    let
      unknown = builtins.attrNames (removeAttrs value [ "max" ]);
    in
    if value == null then
      null
    else if !builtins.isAttrs value then
      throw "[${where}] meta.availability is a ${builtins.typeOf value}. Write meta.availability.max = \"<level>\"."
    else if unknown != [ ] then
      throw "[${where}] meta.availability has unknown key(s) ${lib.concatStringsSep ", " unknown}. The only key is max."
    else
      value.max or null;

  # `pick` and `atLeast` as handed to a package whose meta.availability.max
  # is `ceiling` ("ns/inst" in `where`). `resolve` caps the level at the
  # ceiling, so the package never sees a higher level and `pick` is
  # unchanged. An `atLeast` threshold above the ceiling is always false, so
  # it throws.
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
            throw (
              "[${where}] kix.availability.atLeast \"${min}\": meta.availability.max is \"${ceiling}\", "
              + "so this test is always false. Put the ceiling on the builder calls of the workloads that "
              + "cannot reach \"${min}\", or remove the test."
            )
          else
            atLeast min level;
      };

  # The largest level the substrate can honour, and whether that is known.
  # `certain = false` when the capabilities that decide it are unknown
  # under three-valued logic. Asking above an uncertain substrate warns;
  # asking above a certain one is an error.
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

  # Topology spread constraints for pods at `level`, selected by `selector`
  # (a matchLabels set). `topology` has the shape of
  # clusterConfig.cluster.topology: { zoneKey, hostKey, failureDomainKeys }.
  # One constraint per failure-domain key, outermost first; a single-node
  # cluster has no keys and gets [ ].
  #
  # The plugin derives spread for the workloads Kix renders. A package calls
  # this for operator-placed operands whose custom resource takes a pod-spec
  # spread list:
  #
  #   kix.availability.spreadConstraints {
  #     level = availability;
  #     selector = operandSelector;
  #     topology = clusterConfig.cluster.topology;
  #   }
  spreadConstraints =
    {
      level,
      selector,
      topology,
    }:
    let
      # DoNotSchedule on the key the requested level names, ScheduleAnyway
      # on the others. maxSkew = 1 allows more replicas than domains while
      # keeping their distribution within one pod.
      whenUnsatisfiable =
        key:
        if level == "zone" && key == topology.zoneKey then
          "DoNotSchedule"
        else if level == "node" && key == topology.hostKey then
          "DoNotSchedule"
        else
          "ScheduleAnyway";
    in
    # nodeTaintsPolicy = "Honor" leaves nodes the pods cannot tolerate out of
    # the counts. Otherwise an unschedulable control-plane node can make a
    # hard hostname constraint block further worker pods.
    map (key: {
      topologyKey = key;
      maxSkew = 1;
      whenUnsatisfiable = whenUnsatisfiable key;
      nodeTaintsPolicy = "Honor";
      labelSelector.matchLabels = selector;
    }) topology.failureDomainKeys;

  # The ladder for one instance: instance override, else cluster default;
  # capped by the package ceiling (meta.availability.max) with a warning;
  # refused above the substrate.
  resolve =
    {
      capabilities,
      clusterDefault,
      instanceOverride ? null,
      # meta.availability.max as the package wrote it
      ceiling ? null,
      # "ns/inst", for messages
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
          throw (
            "[${where}] ${requestedFrom} = \"${requested}\" but the cluster can offer at most "
            + "\"${sub.level}\": it needs ${needs}. Lower the availability level, or update the capability declaration if the cluster supports it."
          )
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
