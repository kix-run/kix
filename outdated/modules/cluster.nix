# modules/cluster.nix — cluster-wide options that are genuinely cluster-scoped.
#
# Only options that apply uniformly across an entire Kubernetes cluster belong
# here. Per-service concerns (namespace, release identity) live in each chart's
# own options — real clusters have services spread across multiple namespaces.
#
# What belongs here:
#   - cluster.domain: the cluster DNS domain (almost always "cluster.local")
#   - cluster.labels: org-wide labels applied to every resource (team, env, etc.)
#
# What does NOT belong here:
#   - namespace: per-service (coredns in kube-system, valkey in cache, etc.)
#   - releaseName: a Helm-ism; each service has its own identity
#
# Charts consume cluster.domain via mkDefault in their config section:
#   config.services.valkey.clusterDomain = lib.mkDefault config.cluster.domain;
#
# Charts merge cluster.labels into their allLabels computation, so chart-specific
# labels (like app.kubernetes.io/name) take precedence on key collision.

{
  lib,
  ...
}:

let
  types = lib.types;
in
{
  options.cluster = {
    domain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = ''
        Kubernetes cluster DNS domain. Used for constructing FQDNs in
        service discovery (e.g., valkey-headless.cache.svc.cluster.local).
        Most clusters use "cluster.local" but custom domains exist.
      '';
    };

    labels = lib.mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Labels applied to ALL resources across all charts.
        Useful for organization-wide labels like team, environment,
        cost-center — anything that should appear on every resource.
        Chart-specific labels take precedence on key collision.
      '';
    };
  };
}
