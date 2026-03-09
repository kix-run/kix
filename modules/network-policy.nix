# modules/network-policy.nix — Level 3 of intent merging: cross-cutting network policy.
#
# HISTORY & MOTIVATION (2026-03):
#
# Currently valkey creates its own NetworkPolicy directly. When we have 10+
# charts, each creating their own policies independently, there's no way to:
#
#   1. See the full network topology at a glance
#   2. Automatically allow traffic between declared dependencies
#   3. Apply cluster-wide default-deny policies
#   4. Validate that declared dependencies actually exist in the registry
#
# This module provides option types for charts to declare their network surface
# area — what ports they listen on, what other services they talk to. A future
# materialization step (not yet implemented) will generate NetworkPolicy
# resources from these declarations, using the service registry (Level 2) to
# resolve endpoint details.
#
# HOW IT WORKS (PLANNED):
#
# Charts declare their network requirements:
#
#   config.networkPolicies.services.valkey = lib.mkIf cfg.enable {
#     namespace = cfg.namespace;
#     podSelector = selectorLabels;
#     ingressPorts = [ 6379 ] ++ lib.optionals cfg.sentinel.enabled [ 26379 ];
#     egressTo = [];  # valkey doesn't initiate connections to other kix services
#   };
#
# When `networkPolicies.enabled = true`, this module would:
#   - Generate ingress NetworkPolicies allowing traffic to declared ports
#   - Generate egress NetworkPolicies allowing traffic to declared dependencies
#   - Optionally generate default-deny policies per namespace
#   - Resolve `egressTo` entries via config.registry for port/host details
#
# CURRENT STATUS: SKELETON
#
# This file defines the option types but does NOT yet materialize NetworkPolicy
# resources. With only 2 charts (coredns, valkey), cross-service network
# dependencies aren't interesting yet — neither chart talks to the other.
# When a third chart arrives that depends on valkey (e.g., a web app), the
# materialization logic becomes meaningful.
#
# The option types are defined now so that:
#   1. Charts can start declaring their network surface area immediately
#   2. The pattern is established before many charts need refactoring
#   3. The design is documented while the thinking is fresh
#
# ALTERNATIVES CONSIDERED:
#
# 1. Replacing per-chart NetworkPolicies immediately (like the monitoring
#    capability system does for ServiceMonitors).
#    Deferred: network policies are more complex than monitoring. A chart's
#    NetworkPolicy may include non-kix traffic rules (e.g., allow traffic from
#    any pod, allow DNS egress). The cross-cutting module would need to handle
#    these edge cases. Better to wait for real use cases.
#
# 2. Inferring network requirements from the registry.
#    Rejected: not all consumers of a service are kix-managed. A policy that
#    only allows traffic from registered kix services would break external
#    clients. Explicit declaration is needed.
#
# EVOLUTION:
#
# When the first chart-to-chart dependency is migrated, implement:
#   - Materialization of NetworkPolicy resources from declarations
#   - Registry-based resolution of egressTo targets
#   - Optional default-deny generation
#   - Migration path from per-chart to cross-cutting policies

{
  lib,
  ...
}:

let
  types = lib.types;
in
{
  options.networkPolicies = {
    enabled = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable cross-cutting network policy generation.
        Currently a skeleton — option types are defined but no
        NetworkPolicy resources are materialized yet.
      '';
    };

    defaultDeny = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        When true (and enabled = true), generate a default-deny-all
        NetworkPolicy for each namespace that has kix-managed services.
        Charts must explicitly declare their ingress/egress requirements.
        NOT YET IMPLEMENTED — defined for forward compatibility.
      '';
    };

    services = lib.mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          namespace = lib.mkOption {
            type = types.str;
            description = "Namespace of the service.";
          };

          podSelector = lib.mkOption {
            type = types.attrsOf types.str;
            description = ''
              Label selector matching the service's pods.
              Used as spec.podSelector.matchLabels in the generated
              NetworkPolicy.
            '';
          };

          ingressPorts = lib.mkOption {
            type = types.listOf types.int;
            default = [ ];
            description = ''
              Ports that accept incoming traffic. The generated
              NetworkPolicy will allow ingress to these ports from
              any source (or from declared dependents, depending on
              defaultDeny setting).
            '';
          };

          egressTo = lib.mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              List of registry service names this service needs to reach.
              E.g., ["valkey"] means "allow egress to valkey's primary
              endpoint port". Resolved via config.registry at materialization
              time.
            '';
          };
        };
      });
      default = { };
      description = ''
        Network surface area declarations from chart modules.
        Each chart declares what ports it listens on and what other
        services it depends on. Currently informational only — used
        for documentation and future NetworkPolicy generation.
      '';
    };
  };

  # No config section yet — materialization deferred until we have
  # real cross-chart network dependencies. See "CURRENT STATUS" above.
}
