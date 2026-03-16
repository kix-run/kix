# modules/registry.nix — Level 2 of intent merging: service registry.
#
# HISTORY & MOTIVATION (2026-03):
#
# Charts produce Kubernetes Services with specific DNS names and ports. When
# multiple charts are evaluated together, consumers need to reference these
# endpoints. Without a registry, a future "app" chart connecting to valkey
# would hardcode "valkey-primary.default.svc.cluster.local:6379" and break
# if the user changes valkey's namespace, port, or switches between sentinel
# and replication mode (which changes which Service to connect to).
#
# This module provides a structured registry where charts declare their
# endpoints, and consumers read them by name.
#
# HOW IT WORKS:
#
# Each chart writes to `config.registry.<serviceName>.endpoints.<endpointName>`:
#
#   config.registry.valkey.endpoints.primary = {
#     host = "valkey-primary.prod.svc.cluster.local";
#     port = 6379;
#     protocol = "redis";
#   };
#
# Consumers reference: `config.registry.valkey.endpoints.primary.host`
#
# The host values are COMPUTED from the chart's internal logic (namespace,
# service names, cluster domain). They reflect the chart's current mode —
# e.g., valkey's primary endpoint changes between sentinel and replication
# mode. This is the key advantage over hardcoding: the endpoint adapts
# automatically when the chart's configuration changes.
#
# PRIOR ART — KUBENIX:
#
# kubenix has NO service registry. Consumers reference resources by reaching
# directly into the config tree:
#   config.kubernetes.resources.configMaps.nginx-config.metadata.name
#
# This works in kubenix because all resources live in a flat namespace
# (`kubernetes.resources.<kind>.<name>`). Our approach with `registry.*` is
# MORE structured — it formalizes what kubenix leaves to convention, and
# provides mode-aware endpoints (sentinel vs replication is invisible to
# consumers).
#
# ALTERNATIVES CONSIDERED:
#
# 1. Using a separate `outputs` option namespace to distinguish chart inputs
#    from chart outputs.
#    Rejected: NixOS modules have a single `config` tree — splitting into
#    "inputs" and "outputs" fights the module system. Instead, we use the
#    convention that `registry.*` is written by charts, read by consumers.
#
# 2. Using `types.submoduleWith` with freeformType for endpoint metadata
#    (e.g., TLS settings, authentication methods).
#    Rejected for now: explicit fields are safer and give better error messages.
#    We can add freeformType later if charts need to advertise custom metadata.
#
# 3. Auto-populating the registry from kixlib resource construction.
#    Rejected: too implicit. Charts know their own topology better than a
#    generic builder. Explicit declaration in the chart module is clearer.
#
# OWNERSHIP CONVENTION:
#
# The NixOS module system has no "read-only" mechanism for leaf option values.
# We rely on convention: only the chart that owns a service name writes to
# its registry entry. This is similar to how NixOS `networking.interfaces`
# is written by network modules and read by firewall modules.
#
# EVOLUTION:
#
# Cross-cutting modules (monitoring capability, network-policy) consume the registry.
# Monitoring reads endpoints to find scrape targets for validation.
# Network policy modules read endpoints to know which ports need rules.
# Future chart modules will reference registry entries for service discovery.

{
  lib,
  ...
}:

let
  types = lib.types;

  # A single network endpoint exposed by a service.
  # Using { host, port, protocol } rather than a URI string because consumers
  # typically need these parts separately: network policy needs just the port,
  # DNS resolution needs just the host, connection strings need all three.
  # A URI can be derived from parts; the reverse requires fragile parsing.
  endpointType = types.submodule {
    options = {
      host = lib.mkOption {
        type = types.str;
        description = "DNS hostname (typically <svc>.<ns>.svc.<domain>).";
      };

      port = lib.mkOption {
        type = types.int;
        description = "Port number.";
      };

      protocol = lib.mkOption {
        type = types.str;
        default = "tcp";
        description = ''
          Application-level protocol. Examples: "redis", "redis-sentinel",
          "dns-udp", "dns-tcp", "http", "grpc". Not the transport protocol
          (TCP/UDP) — Kubernetes Services handle that. This is for consumers
          to understand what kind of client to use.
        '';
      };
    };
  };

  # A service entry in the registry. Each chart gets one entry (keyed by
  # chart name), containing multiple named endpoints.
  # E.g., valkey has "primary", "sentinel", "metrics" endpoints.
  serviceType = types.submodule {
    options = {
      endpoints = lib.mkOption {
        type = types.attrsOf endpointType;
        default = { };
        description = ''
          Named endpoints this service exposes. Consumers reference them as:
            config.registry.<service>.endpoints.<name>.host
          Example: { primary = { host = "..."; port = 6379; protocol = "redis"; }; }
        '';
      };
    };
  };
in
{
  options.registry = lib.mkOption {
    type = types.attrsOf serviceType;
    default = { };
    description = ''
      Service registry. Charts declare their endpoints here so other charts
      and cross-cutting modules can discover them without hardcoding DNS names.
      Keyed by chart/service name (e.g., "valkey", "coredns").
    '';
  };
}
