# clusters/test-n8n.nix: n8n in queue mode on kind, under Cilium's default
# deny.
#
# The n8n namespace declares n8n, its database, its encryption key, and the
# password of the valkey that auto-instantiation adds beside it. The
# stackgres-cluster behind the database is an optional instance, created
# because the database depends on it.
# ingress-nginx routes n8n.localtest.me, a name that resolves to 127.0.0.1.
#
# Build:   nix build .#cluster-n8n --extra-experimental-features pipe-operators
# Kind:    a cluster created with `networking.disableDefaultCNI: true`, then
#          kix --flake ./clusters --context kind-<name> deploy n8n -y
# Reach:   kubectl -n ingress-system port-forward svc/ingress-nginx 8080:80
#          curl -H 'Host: n8n.localtest.me' localhost:8080/healthz

{ kix, packages }:

kix.buildCluster {
  name = "n8n";
  modules = [
    kix.flavors.kind

    {
      availablePackages = packages;
      networkPolicy.enable = true;

      # kind runs with the default CNI disabled; the managed cilium
      # instance fills the cni role, as homelab-kind does.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      instances.kube-system.cilium.package = packages.cilium;

      instances.ingress-system.ingress-nginx.package = packages.ingress-nginx;

      # The operator is cluster-wide; one instance serves every namespace.
      instances.stackgres-system.stackgres-operator.package = packages.stackgres-operator;

      # Test values only; they protect nothing.
      instances.n8n = {
        # StackGres and CloudNativePG both answer `postgres`; this
        # optional instance picks StackGres for the database below.
        stackgres-cluster = {
          package = packages.stackgres-cluster;
          optional = true;
        };
        n8n = {
          package = packages.n8n;
          config = {
            ingress.host = "n8n.localtest.me";
            # The route serves plain http, where a browser drops n8n's
            # secure session cookie.
            env.N8N_SECURE_COOKIE = "false";
          };
        };
        database = {
          package = packages.stackgres-database;
          config.password = "n8n-test-db-password";
        };
        n8n-encryption-key = {
          package = packages.secret;
          aliases = [ "encryptionKey" ];
          config.stringData.key = "0123456789abcdef0123456789abcdef";
        };
        valkey-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "n8n-test-valkey-password";
        };
      };
    }
  ];
}
