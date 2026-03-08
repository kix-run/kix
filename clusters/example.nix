# clusters/example.nix — Example cluster: coredns + valkey + cert-manager.
#
# This is what "declarative cluster state" looks like in kixpkgs.
# One file declares what runs in your cluster. Services get their own
# namespaces, the registry populates automatically, and cross-cutting
# modules (monitoring) aggregate across all services.
#
# Build:  nix build .#cluster-example
# Check:  nix flake check

{
  # --- Cluster-wide settings ---
  # These apply to every resource across all charts.
  cluster.labels = {
    "app.kubernetes.io/part-of" = "kix-example";
    "team" = "platform";
  };

  # --- Services ---
  # Each service declares its own namespace — real clusters don't
  # shove everything into one namespace.

  services.coredns = {
    enable = true;
    namespace = "kube-system";
    replicaCount = 2;
    prometheus.service.enabled = true;
    prometheus.monitor.enabled = true;
  };

  services.valkey = {
    enable = true;
    namespace = "cache";
    sentinel.enabled = true;
    metrics.enabled = true;
    metrics.serviceMonitor.enabled = true;
    # Auth secret must exist in the target cluster — kix never generates secrets.
    auth.existingSecret = "valkey-auth";
  };

  services.cert-manager = {
    enable = true;
    namespace = "cert-manager";
  };

  # --- Cross-cutting concerns ---
  # monitoring.enabled = true activates Level 3 intent merging:
  # the monitoring module creates ServiceMonitors from declared targets
  # across all charts, replacing per-chart ServiceMonitor creation.
  monitoring = {
    enabled = true;
    defaultInterval = "15s";
  };
}
