# clusters/test-external-dns-upgrade.nix: external-dns under Cilium
# default-deny, for testing a version change on kind.
#
# - `bind` writes to a BIND server through `rfc2136`. BIND keeps the records
#   and the TXT ownership records across a restart of external-dns, so a
#   new version can be checked against what the old one wrote. A namespace
#   NetworkPolicy lets it reach BIND on port 53.
# - `gateway` reads HTTPRoutes with the `inmemory` provider. The gateway-api
#   instance installs the CRDs.
# - prometheus-operator gives both instances a metrics Service, a
#   ServiceMonitor, and alerts.
#
# BIND runs outside Kix, from test-external-dns-upgrade.bind.yaml, in
# namespace `dns-server`. Its Service is `bind.dns-server`.
#
# Bring up: kind create cluster --name <name> --config <config>
#           where the config sets networking.disableDefaultCNI = true
#           kubectl apply -f clusters/test-external-dns-upgrade.bind.yaml
# Deploy:   kix deploy external-dns-upgrade --context kind-<name> -y
# Use:      annotate a Service in any namespace with
#           external-dns.kubernetes.io/hostname=<name>.example.test, then
#           `dig @127.0.0.1 example.test AXFR` in the BIND pod lists its A
#           record and a TXT record owned by test-external-dns-bind.

{ kix, packages }:

kix.buildCluster {
  name = "external-dns-upgrade";
  modules = [
    kix.flavors.kind

    {
      cluster.availability.default = "none";
      # kind runs with the default CNI disabled, so the managed cilium
      # instance fills the cni role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;
      instances.kube-system.cilium.package = packages.experimental.cilium;

      instances.gateway-api.gateway-api.package = packages.experimental.gateway-api;
      instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

      namespaces.external-dns.networkPolicies.allow-bind = {
        podSelector = { };
        policyTypes = [ "Egress" ];
        egress = [
          {
            to = [ { namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "dns-server"; } ];
            ports = [
              {
                port = 53;
                protocol = "UDP";
              }
              {
                port = 53;
                protocol = "TCP";
              }
            ];
          }
        ];
      };

      instances.external-dns.bind = {
        package = packages.experimental.external-dns;
        config = {
          provider = "rfc2136";
          policy = "sync";
          txtOwnerId = "test-external-dns-bind";
          sources = [ "service" ];
          interval = "10s";
          extraArgs = [
            "--domain-filter=example.test"
            "--publish-internal-services"
            "--rfc2136-host=bind.dns-server"
            "--rfc2136-port=53"
            "--rfc2136-zone=example.test"
            "--rfc2136-insecure"
            "--rfc2136-axfr"
            "--log-level=debug"
          ];
        };
      };

      instances.external-dns-gateway.gateway = {
        package = packages.experimental.external-dns;
        config = {
          provider = "inmemory";
          policy = "sync";
          txtOwnerId = "test-external-dns-gateway";
          sources = [ "gateway-httproute" ];
          interval = "10s";
          extraArgs = [
            "--inmemory-zone=example.test"
            "--log-level=debug"
          ];
        };
      };
    }
  ];
}
