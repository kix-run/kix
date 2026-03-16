# clusters/example.nix — Example cluster: coredns + valkey + cert-manager.
#
# This is what "declarative cluster state" looks like in the fixpoint pattern.
# One file declares what runs in your cluster. Package closures handle
# dependency tracking — you don't list resources, you list packages.
#
# Build:  nix build .#cluster-example
# DAG:    nix eval --raw .#legacyPackages.<system>.fpClusterExample.dagTree

{ k8s, lib }:

let
  clusterLabels = {
    "app.kubernetes.io/part-of" = "kix-example";
    "team" = "platform";
  };
in

k8s.mkCluster {
  basePackages = self: {
    coredns = (import ../pkgs-fp/coredns { inherit k8s lib; }).override {
      namespace = "kube-system";
      replicaCount = 2;
      prometheus = {
        service = {
          enabled = true;
          annotations = {
            "prometheus.io/scrape" = "true";
            "prometheus.io/port" = "9153";
          };
        };
        monitor = {
          enabled = true;
          interval = null;
        };
      };
      inherit clusterLabels;
    };

    valkey = (import ../pkgs-fp/valkey { inherit k8s lib; }).override {
      namespace = "cache";
      sentinel = {
        enabled = true;
        quorum = 2;
        primarySet = "myprimary";
        downAfterMilliseconds = 60000;
        failoverTimeout = 180000;
        parallelSyncs = 1;
        configuration = "";
        image = {
          repository = "docker.io/bitnami/valkey-sentinel";
          tag = "8.1.1-debian-12-r0";
          pullPolicy = "IfNotPresent";
        };
        resources = {
          requests = {
            cpu = "100m";
            memory = "128Mi";
            ephemeral-storage = "50Mi";
          };
          limits = {
            cpu = "150m";
            memory = "192Mi";
            ephemeral-storage = "2Gi";
          };
        };
      };
      metrics = {
        enabled = true;
        image = {
          repository = "docker.io/bitnami/redis-exporter";
          tag = "1.70.0-debian-12-r2";
          pullPolicy = "IfNotPresent";
        };
        resources = {
          requests = {
            cpu = "100m";
            memory = "128Mi";
            ephemeral-storage = "50Mi";
          };
          limits = {
            cpu = "150m";
            memory = "192Mi";
            ephemeral-storage = "2Gi";
          };
        };
      };
      auth = {
        enabled = true;
        existingSecret = "valkey-auth";
        existingSecretPasswordKey = "valkey-password";
        sentinel = true;
      };
      inherit clusterLabels;
    };

    cert-manager = (import ../pkgs-fp/cert-manager { inherit k8s lib; }).override {
      namespace = "cert-manager";
      inherit clusterLabels;
    };
  };
}
