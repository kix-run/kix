# Tests for the `platform-dns` import every built-in flavour declares: its
# `out.name` and `out.fqdn` both name the platform's DNS Service, its marker
# names that Service for the deploy check.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");

  # Write the out of the `dns` provider into a ConfigMap. The required `dns`
  # argument activates an optional platform-dns import.
  dnsProbe = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        dns,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "dns-facts";
          data = {
            name = toString dns.out.name;
            fqdn = builtins.unsafeDiscardStringContext (toString dns.out.fqdn);
          };
        };
        root = self.cm;
      };
  };

  # Return the probe's view of the dns provider and the platform-dns marker's
  # annotations on flavour `name`.
  dnsFacts =
    name:
    let
      ms = manifests (mkCluster [
        (flavor name)
        { instances.probe.facts.package = dnsProbe; }
      ]);
      marker = byName "platform-dns" (ofKind "PackageInstance" ms);
    in
    {
      inherit ((byName "dns-facts" (ofKind "ConfigMap" ms)).data) name fqdn;
      importKind = marker.metadata.annotations.${kixKeys.importKind};
      importName = marker.metadata.annotations.${kixKeys.importName};
    };

  expected = {
    aks = "kube-dns.kube-system";
    eks = "kube-dns.kube-system";
    gke = "kube-dns.kube-system";
    gke-autopilot = "kube-dns.kube-system";
    k3s = "kube-dns.kube-system";
    kind = "kube-dns.kube-system";
    kubeadm = "kube-dns.kube-system";
    openshift = "dns-default.openshift-dns";
    ovh = "kube-dns.kube-system";
    rke2 = "rke2-coredns-rke2-coredns.kube-system";
    scaleway = "kube-dns.kube-system";
    talos = "kube-dns.kube-system";
  };
in
{
  # On every flavour, out.name is the Service that out.fqdn addresses, and
  # the marker asks the deploy check for that Service.
  flavor-dns-import-names-one-service = lib.all (
    name:
    let
      facts = dnsFacts name;
      service = lib.head (lib.splitString "." expected.${name});
    in
    (
      facts.fqdn == "${expected.${name}}.svc.cluster.local"
      && facts.name == service
      && facts.importKind == "Service"
      && facts.importName == service
    )
    || throw "flavour ${name}: platform-dns gives ${builtins.toJSON facts}"
  ) (builtins.attrNames expected);
}
