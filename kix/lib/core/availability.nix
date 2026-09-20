# The availability level: one word for how much
# failure a workload must survive, and the arithmetic every consumer of it
# shares. Design: v2_discussions/archive/145_availability_level.md.
#
#   none  downtime on any failure or update is accepted
#   pod   a pod crash or a rolling update causes no downtime
#   node  the loss of one node causes no downtime      (needs multiNode)
#   zone  the loss of one zone causes no downtime      (needs two or more zones)
#
# Pure: no module system, no scope. `resolve` is called once per instance
# by eval/instance.nix; `pick` and `atLeast` are what packages see as
# `kix.availability`.
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

  # atLeast "node" level: true for node and zone.
  atLeast = min: level: rank level >= rank min;

  # pick level { none = 1; pod = 2; node = 2; zone = 3; }. Every level must
  # be present so a package's mapping is complete by construction.
  pick =
    level: table:
    let
      missing = builtins.filter (l: !(table ? ${l})) levels;
    in
    if missing != [ ] then
      throw "kix.availability.pick: table is missing ${lib.concatStringsSep ", " missing} (need every level: ${lib.concatStringsSep ", " levels})"
    else
      table.${level};

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

  # The ladder for one instance: instance override, else cluster default;
  # capped by the package ceiling (meta.availability.max) with a warning;
  # refused above the substrate.
  resolve =
    {
      capabilities,
      clusterDefault,
      instanceOverride ? null,
      ceiling ? null,
      # "ns/inst", for messages
      where,
    }:
    let
      sub = substrate capabilities;
      requested = if instanceOverride != null then instanceOverride else clusterDefault;
      requestedFrom =
        if instanceOverride != null then
          "instances.${where}.availability"
        else
          "cluster.availability.default";
      overSubstrate = rank requested > rank sub.level;
      capped = ceiling != null && rank requested > rank ceiling;
      level = if capped then ceiling else requested;
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
        ceiling
        capped
        ;
      substrate = sub;
      warnings =
        lib.optional (overSubstrate && !sub.certain) (
          "[${where}] ${requestedFrom} = \"${requested}\" needs ${needs}, which this cluster has not declared. "
          + "Set the capability to match your environment, or lower the availability level. Kix cannot verify the requested availability without this information."
        )
        ++ lib.optional capped (
          "[${where}] availability \"${requested}\" was requested but the package declares "
          + "meta.availability.max = \"${ceiling}\", so it runs at \"${ceiling}\". "
          + "This instance does not meet the requested availability level."
        );
    };
in
{
  inherit
    levels
    rank
    atLeast
    pick
    substrate
    resolve
    ;
}
