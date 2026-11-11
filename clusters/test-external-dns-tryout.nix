# clusters/test-external-dns-tryout.nix: the kind tryout from the
# external-dns how-to. One instance with the `inmemory` provider, which needs
# no credentials, no egress, and no CRDs.
#
# kind gives Services no LoadBalancer addresses, so the instance publishes
# an A record per node through `--fqdn-template`. Its debug log shows the
# records it writes.
#
# Bring up:  kind create cluster --name external-dns
# Deploy:    kix deploy external-dns-tryout --flake ./clusters --context kind-external-dns -y
{ kix, packages }:

kix.buildCluster {
  name = "external-dns-tryout";
  modules = [
    kix.flavors.kind

    {
      # region:externalDnsKindTryout
      instances.external-dns.nodes = {
        package = packages.experimental.external-dns;
        config = {
          provider = "inmemory";
          policy = "sync";
          txtOwnerId = "kind-tryout/nodes";
          sources = [ "node" ];
          extraArgs = [
            "--inmemory-zone=example.test"
            "--fqdn-template={{.Name}}.example.test"
            "--log-level=debug"
          ];
        };
      };
      # endregion:externalDnsKindTryout
    }
  ];
}
