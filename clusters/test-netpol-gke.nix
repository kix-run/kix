# clusters/test-netpol-gke.nix: generated network policy on the gke flavor,
# which writes standard NetworkPolicy objects for GKE Dataplane V2.
#
# - `np/echo-server` sits behind a LoadBalancer Service, so it gets ingress
#   from outside the cluster.
# - `external-dns/clouddns` gets Google Cloud credentials from the metadata
#   server, calls the API server, and calls Cloud DNS on the internet.
# - `cert-manager/cert-manager` serves an admission webhook, which the API
#   server calls through the konnectivity-agent pods.
# - `external-secrets/external-secrets` serves webhooks and metrics that
#   Prometheus scrapes.
# - The monitoring module's Prometheus scrapes node-exporter, which runs on
#   the host network, so its rule uses `cluster.network.nodeCidrs`.
#
# The addresses are examples. A real cluster sets its own control plane
# address and node range.
#
# Build:   kix check netpol-gke
{ kix, packages }:

kix.buildCluster {
  name = "netpol-gke";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.gke
    kix.modules.experimental.monitoring

    {
      networkPolicy.enable = true;
      cluster.network = {
        apiServer.cidrs = [ "10.0.0.2/32" ];
        nodeCidrs = [ "10.128.0.0/20" ];
      };

      instances.np.echo-server = {
        package = packages.echo-server;
        config.service.type = "LoadBalancer";
      };

      instances.external-dns.clouddns = {
        package = packages.experimental.external-dns;
        deps.providerCredentials = kix.cloudIdentity.gcp { };
        config = {
          provider = "google";
          policy = "upsert-only";
          txtOwnerId = "netpol-gke";
          extraArgs = [
            "--google-project=my-project"
            "--domain-filter=example.com"
          ];
        };
      };

      instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;

      # Its metrics Services are named after its Deployments, which the
      # scrape join must read as plain names.
      instances.external-secrets.external-secrets.package = packages.experimental.external-secrets;

      monitoring.enabled = true;
      # Test values only.
      instances.monitoring-system.grafana-admin = {
        package = packages.secret;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "test-only";
        };
      };
    }
  ];
}
