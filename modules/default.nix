# Base module for kixpkgs — imports all shared module infrastructure.
#
# ARCHITECTURE:
#
# kixpkgs uses the NixOS module system (lib.evalModules) for chart evaluation.
# Intent merging happens at three levels:
#
#   Level 1 — cluster.nix: Cluster-wide defaults (namespace, domain, labels).
#     Charts consume these via lib.mkDefault, so cluster-level settings apply
#     everywhere but per-chart overrides still win.
#
#   Level 2 — registry.nix: Service endpoint registry.
#     Charts declare their endpoints (host, port, protocol). Other charts or
#     modules can reference them without hardcoding DNS names.
#
#   Level 3 — Capabilities + implementations:
#     Charts declare abstract intent via capabilities (e.g., capabilities.monitoring.*).
#     Capability submodules compute output metadata (labels, annotations) from inputs.
#     Implementation modules (e.g., monitoring-prometheus.nix) read capability inputs
#     and materialize shared resources (ServiceMonitors). Charts read output metadata
#     to merge into their own resources (e.g., Service labels).
#     network-policy.nix is a skeleton for future NetworkPolicy generation.
#
# All levels are always loaded, even for single-chart evaluation. This is safe
# because Nix is lazy — unused options are declared but never evaluated, so
# there is zero overhead for charts that don't participate.

{
  lib,
  ...
}:

{
  imports = [
    ./cluster.nix
    ./registry.nix
    ./capabilities/monitoring.nix
    ./implementations/monitoring-prometheus.nix
    ./network-policy.nix
  ];

  # Manifest type that errors on key collision between modules.
  # Without this, `types.attrsOf types.anything` silently merges values from
  # different modules — so two charts writing the same manifest key would
  # silently overwrite each other. This custom type makes that a hard error
  # with a clear message showing which module files collided.
  #
  # DESIGN: manifests stores raw attrsets, NOT derivations.
  # Serialization (removeNulls → toJSON → writeText) is deferred to the
  # output boundary (mkManifests in flake.nix). This keeps structured data
  # available throughout the module system for cross-resource validation,
  # behavioral invariants, and any module that needs to inspect other
  # charts' resources.
  options.manifests = lib.mkOption {
    type = lib.types.attrsOf (lib.types.mkOptionType {
      name = "manifest";
      description = "Kubernetes resource attrset (must have kind and apiVersion)";
      check = v: builtins.isAttrs v && v ? kind && v ? apiVersion;
      merge = loc: defs:
        if builtins.length defs == 1
        then (builtins.head defs).value
        else throw "Manifest key collision at ${lib.showOption loc}: defined by ${lib.concatMapStringsSep ", " (d: d.file) defs}";
    });
    default = { };
    description = ''
      Collected Kubernetes resource attrsets from all enabled modules.
      Each value is a plain attrset with at least `kind` and `apiVersion`.
      Keyed by human-readable name (e.g., "coredns-deployment", "valkey-primary").

      Chart modules write here: config.manifests."coredns-deployment" = <attrset>;
      Implementation modules also write here (e.g., ServiceMonitors).
      The flake's mkManifests serializes all entries to JSON at the output boundary.
    '';
  };
}
