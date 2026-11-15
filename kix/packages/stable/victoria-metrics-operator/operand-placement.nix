# Spread and disruption budget for the pods the VictoriaMetrics operator
# renders, shared by victoria-metrics-cluster, -agent, and -alert.
#
# Kix derives topology spread and a PodDisruptionBudget only for workloads
# it renders. The operator renders these pods, so each CR carries the same
# fields the derivation would give: one spread constraint per failure-domain
# key at the instance's availability level, and a budget of one pod. A
# single replica gets neither, as a Kix-rendered workload does.
{ lib, kix }:
{
  # Return the CR spec fields that place `replicas` pods selected by
  # `selector` at `availability` across `topology`.
  operandPlacement =
    {
      availability,
      topology,
      selector,
      replicas,
    }:
    let
      constraints = kix.availability.spreadConstraints {
        level = availability;
        inherit selector topology;
      };
    in
    lib.optionalAttrs (replicas > 1) (
      {
        podDisruptionBudget.maxUnavailable = 1;
      }
      # A single-node cluster has no failure-domain key to spread over.
      // lib.optionalAttrs (constraints != [ ]) { topologySpreadConstraints = constraints; }
    );
}
