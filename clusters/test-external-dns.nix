# clusters/test-external-dns.nix: external-dns on kind with the `inmemory`
# provider, which needs no credentials and no egress. The how-to's tryout is
# test-external-dns-tryout.nix; this cluster covers the rest.
#
# - `nodes` publishes an A record per node through `--fqdn-template`, since
#   kind gives Services no LoadBalancer addresses.
# - `services` runs the default sources.
# - `public` and `private` read Gateway API routes and share a namespace;
#   each declares its own CRD reference markers.
# - The `other` namespace holds a secret-ref aliased `providerCredentials`.
#   It serves only its own namespace, so the instances above build without
#   credentials.
# - prometheus-operator gives every instance a metrics Service, a
#   ServiceMonitor, and alerts; test-external-dns.rules-test.yaml tests the
#   rules of `nodes`.
#
# Bring up:  kind create cluster --name external-dns
#            kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
#            kubectl create namespace other
#            kubectl -n other create secret generic other-dns-token --from-literal=x=unused
# Deploy:    kix deploy external-dns --flake ./clusters --context kind-external-dns -y
{ kix, packages }:

kix.buildCluster {
  name = "external-dns";
  modules = [
    kix.flavors.kind

    {
      instances.external-dns.nodes = {
        package = packages.external-dns;
        config = {
          provider = "inmemory";
          policy = "sync";
          txtOwnerId = "test-external-dns-nodes";
          sources = [ "node" ];
          extraArgs = [
            "--inmemory-zone=example.test"
            "--fqdn-template={{.Name}}.example.test"
            "--log-level=debug"
          ];
        };
      };

      instances.external-dns.services = {
        package = packages.external-dns;
        config = {
          provider = "inmemory";
          policy = "sync";
          txtOwnerId = "test-external-dns-services";
          extraArgs = [ "--inmemory-zone=example.test" ];
        };
      };

      instances.external-dns-gateway = {
        public = {
          package = packages.external-dns;
          config = {
            provider = "inmemory";
            policy = "sync";
            txtOwnerId = "test-external-dns-public";
            sources = [ "gateway-httproute" ];
            extraArgs = [ "--inmemory-zone=example.test" ];
          };
        };
        private = {
          package = packages.external-dns;
          config = {
            provider = "inmemory";
            policy = "sync";
            txtOwnerId = "test-external-dns-private";
            sources = [ "gateway-httproute" ];
            extraArgs = [ "--inmemory-zone=internal.example.test" ];
          };
        };
      };

      instances.monitoring.prometheus-operator.package = packages."prometheus-operator";

      instances.other.other-dns-token = {
        package = packages.secret-ref;
        aliases = [ "providerCredentials" ];
        config.keys = [ "x" ];
      };
    }
  ];
}
