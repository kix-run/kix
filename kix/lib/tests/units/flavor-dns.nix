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
      importNamespace =
        marker.metadata.annotations.${kixKeys.importNamespace} or marker.metadata.namespace;
    };

  importNamespace = name: if name == "gke-autopilot" then "gke-managed" else "kube-system";

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
      && facts.importNamespace == lib.last (lib.splitString "." expected.${name})
      && facts.name == service
      && facts.importKind == "Service"
      && facts.importName == service
    )
    || throw "flavour ${name}: platform-dns gives ${builtins.toJSON facts}"
  ) (builtins.attrNames expected);

  # The marker names the Service's namespace only when the instance lives
  # elsewhere, so markers in the Service's namespace stay as they were.
  flavor-dns-marker-names-namespace-only-when-elsewhere = lib.all (
    name:
    let
      marker = byName "platform-dns" (
        ofKind "PackageInstance" (
          manifests (mkCluster [
            (flavor name)
            { instances.${importNamespace name}.platform-dns.optional = false; }
          ])
        )
      );
      stamped = marker.metadata.annotations ? ${kixKeys.importNamespace};
    in
    stamped == builtins.elem name [
      "gke-autopilot"
      "openshift"
    ]
    || throw "flavour ${name}: import-namespace stamped is ${builtins.toJSON stamped}"
  ) (builtins.attrNames expected);

  # On every flavour, a cluster definition can set `platform-dns.optional`
  # to either value without lib.mkForce. Setting it to false activates the
  # import with no dependent, and the marker appears.
  flavor-dns-optional-is-overridable = lib.all (
    name:
    let
      ns = importNamespace name;
      markerWhen =
        optional:
        byName "platform-dns" (
          ofKind "PackageInstance" (
            manifests (mkCluster [
              (flavor name)
              { instances.${ns}.platform-dns.optional = optional; }
            ])
          )
        );
    in
    (markerWhen false != null && markerWhen true == null)
    || throw "flavour ${name}: platform-dns.optional does not follow the cluster definition"
  ) (builtins.attrNames expected);

  # Without a dependent or an override, the import stays dormant on every
  # flavour except kind, which needs DNS to exist.
  flavor-dns-optional-default = lib.all (
    name:
    let
      marker = byName "platform-dns" (ofKind "PackageInstance" (manifests (mkCluster [ (flavor name) ])));
    in
    (marker != null) == (name == "kind")
    || throw "flavour ${name}: platform-dns active is ${builtins.toJSON (marker != null)}"
  ) (builtins.attrNames expected);
}
