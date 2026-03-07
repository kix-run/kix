# Base module for kixpkgs — imports all shared module infrastructure.
#
# ARCHITECTURE (2026-03):
#
# kixpkgs uses the NixOS module system (lib.evalModules) for chart evaluation.
# Originally, this was used as a templating engine — each chart evaluated in
# isolation, reading its own options and writing to config.manifests. Luca's
# feedback: "you are not merging intents but more do linear composition."
#
# We've since added three levels of intent merging, building toward a system
# where charts can interact, share defaults, and delegate resource creation
# to cross-cutting modules:
#
#   Level 1 — cluster.nix: Cluster-wide defaults (namespace, domain, labels).
#     Charts consume these via lib.mkDefault, so cluster-level settings apply
#     everywhere but per-chart overrides still win. Validates against kubenix's
#     _m.propagate pattern which does the same thing with more machinery.
#
#   Level 2 — registry.nix: Service endpoint registry.
#     Charts declare their endpoints (host, port, protocol). Other charts or
#     modules can reference them without hardcoding DNS names. More structured
#     than kubenix's approach of reaching directly into the resource config tree.
#
#   Level 3 — monitoring.nix, network-policy.nix: Cross-cutting modules.
#     Aggregate declarations from all charts and materialize shared resources.
#     monitoring.nix creates ServiceMonitors from declared scrape targets.
#     network-policy.nix is a skeleton for future NetworkPolicy generation.
#     Neither kubenix nor Helm has an equivalent — this is novel.
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
    ./monitoring.nix
    ./network-policy.nix
  ];

  options.manifests = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = ''
      Collected Kubernetes manifests from all enabled modules.
      Each value is a Nix store path to a JSON file containing one
      Kubernetes resource. Keyed by human-readable name (e.g.,
      "coredns-deployment", "valkey-primary").

      Chart modules write here: config.manifests."coredns-deployment" = ...;
      Cross-cutting modules (monitoring.nix) also write here.
      The flake's mkManifests collects all entries into a directory.
    '';
  };
}
