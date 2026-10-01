# Tests for the kix/lib behaviour the stackgres rework relies on:
# kix.availability.spreadConstraints, the spread rule for operator-placed
# operands.

{
  kixlib,
  ...
}:

let
  zoneKey = "topology.kubernetes.io/zone";
  hostKey = "kubernetes.io/hostname";
  selector.app = "operand";

  spread =
    level: failureDomainKeys:
    kixlib.availability.spreadConstraints {
      inherit level selector;
      topology = {
        inherit zoneKey hostKey failureDomainKeys;
      };
    };

  constraint = key: whenUnsatisfiable: {
    topologyKey = key;
    maxSkew = 1;
    inherit whenUnsatisfiable;
    nodeTaintsPolicy = "Honor";
    labelSelector.matchLabels = selector;
  };
in
{
  # At zone on a multi-zone cluster: the zone key is hard, the host key soft.
  stackgres-spread-zone =
    let
      got = spread "zone" [
        zoneKey
        hostKey
      ];
    in
    got == [
      (constraint zoneKey "DoNotSchedule")
      (constraint hostKey "ScheduleAnyway")
    ]
    || throw "spreadConstraints at zone: ${builtins.toJSON got}";

  # At node on a single-zone cluster: the host key is hard.
  stackgres-spread-node =
    let
      got = spread "node" [ hostKey ];
    in
    got == [ (constraint hostKey "DoNotSchedule") ]
    || throw "spreadConstraints at node: ${builtins.toJSON got}";

  # A single-node cluster has no failure-domain keys and gets no constraints.
  stackgres-spread-single-node =
    let
      got = spread "none" [ ];
    in
    got == [ ] || throw "spreadConstraints on a single node: ${builtins.toJSON got}";
}
