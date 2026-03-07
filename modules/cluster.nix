# modules/cluster.nix — Level 1 of intent merging: cluster-wide defaults.
#
# HISTORY & MOTIVATION (2026-03):
#
# When kixpkgs started, each chart module (coredns, valkey) was evaluated in
# isolation via mkChartManifests. Every chart independently declared its own
# namespace (defaulting to "default"), release name (hardcoded "release-name"),
# and cluster domain. This worked fine for per-chart parity testing against
# Helm output, but it meant:
#
#   1. No single place to say "everything goes in namespace 'prod'"
#   2. Common values duplicated across every chart module
#   3. No path toward cross-chart references or cluster-wide policies
#
# Luca's feedback (2026-03-07): "It treats each helm chart like a package
# which completely isolates the options from each other. You are not merging
# intents but more do linear composition."
#
# This module is the first of three levels addressing that feedback:
#   Level 1 (this file): Cluster-wide defaults — namespace, domain, labels
#   Level 2 (registry.nix): Service registry — charts advertise endpoints
#   Level 3 (monitoring.nix, network-policy.nix): Cross-cutting resource generation
#
# HOW IT WORKS:
#
# This module defines options under `cluster.*`. Chart modules read these
# values via `lib.mkDefault` in their config sections:
#
#   config.services.valkey.namespace = lib.mkDefault config.cluster.namespace;
#
# Priority chain (lowest → highest):
#   option default ("default") < mkDefault (from cluster) < user assignment
#
# So: `cluster.namespace = "prod"` sets the default for all charts, but
# `services.valkey.namespace = "cache-ns"` still wins for valkey specifically.
# This is the standard NixOS pattern for providing overridable defaults from
# another module.
#
# PRIOR ART — KUBENIX:
#
# kubenix uses `_m.propagate` with feature matching to push `kubernetes.namespace`
# and `kubernetes.version` down to submodules tagged with the "k8s" feature.
# We do the same thing but simpler — no feature matching needed because ALL our
# modules are K8s chart modules. Their pattern validates our approach.
#
# ALTERNATIVES CONSIDERED:
#
# 1. Using kixlib preprocessors to inject namespace/labels.
#    Rejected: preprocessors operate on serialized resources (post-construction),
#    but we need these values DURING construction (e.g., valkey uses namespace in
#    DNS FQDNs for scripts). Preprocessors can't change option values.
#
# 2. Making charts read `config.cluster.*` directly in option defaults.
#    Rejected: referencing `config` from within an option `default` in the same
#    evaluation causes infinite recursion. `mkDefault` in the config section is
#    the correct NixOS pattern.
#
# BACKWARD COMPATIBILITY:
#
# When charts are loaded individually via mkChartManifests, this module is still
# imported (it's part of ./modules). All options default to the same values charts
# previously hardcoded ("default", "cluster.local", "release-name"), so behavior
# is unchanged. Parity tests pass without modification.

{
  lib,
  ...
}:

let
  types = lib.types;
in
{
  options.cluster = {
    namespace = lib.mkOption {
      type = types.str;
      default = "default";
      description = ''
        Default Kubernetes namespace for all chart resources.
        Individual charts can override via services.<name>.namespace.
        The chart-level option uses mkDefault priority, so an explicit
        per-chart setting wins over this cluster-wide default.
      '';
    };

    domain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = ''
        Kubernetes cluster DNS domain. Used for constructing FQDNs in
        service discovery (e.g., valkey-headless.ns.svc.cluster.local).
        Most clusters use "cluster.local" but custom domains exist.
      '';
    };

    releaseName = lib.mkOption {
      type = types.str;
      default = "release-name";
      description = ''
        Equivalent to Helm's release name. Used in the
        app.kubernetes.io/instance label across all charts.
        Helm charts use this pervasively for resource identification.
        We default to "release-name" for parity testing against Helm
        output, but production deployments should set a meaningful name.
      '';
    };

    labels = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Additional labels applied to ALL resources across all charts.
        Merged with (but overridden by) each chart's own labels.
        Useful for organization-wide labels like cost-center, team,
        environment, or any label that should appear on every resource.

        Note: these are merged at the chart level, not via kixlib
        preprocessors. Charts include them in their allLabels computation.
        This means chart-specific labels (like app.kubernetes.io/name)
        take precedence over cluster.labels with the same key.
      '';
    };
  };
}
