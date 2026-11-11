# clusters/test-ingress-netpol.nix: Ingress controller to backend dependency.
#
# Minimal cluster for cross-namespace ingress network policy: a controller in
# one namespace, an exposed backend in another, and default-deny network policy
# enabled. Under Cilium, backend pods reject traffic without an explicit ingress
# rule, and the controller is a normal pod, so without a rule naming it every
# request through the Ingress returns 504. filebrowser is the backend because
# it is one Deployment, one Service, and one `kix.expose`.
#
# Build:  nix build .#cluster-ingress-netpol --extra-experimental-features pipe-operators
#
# Target clusters must already run Cilium. This fixture omits a flavor because
# flavors declare platform instances in `kube-system`, and enabling default-deny
# network policies on a `kube-system` namespace that Kix did not build blocks
# cluster DNS. All resources here live in fixture-owned namespaces.

{ kix, packages }:

kix.buildCluster {
  name = "test-ingress-netpol";
  specialArgs = { inherit packages kix; };
  modules = [
    (
      {
        config,
        lib,
        kix,
        packages,
        ...
      }:
      {
        availablePackages = packages;
        cluster.domain = "lt.test";
        cluster.provider = "rke2";
        networkPolicy.enable = true;
        # One replica of everything: the fixture is about one packet
        # reaching one pod, and its claim is ReadWriteOnce.
        cluster.availability.default = "none";

        # Cilium is installed by the target, and the `platform-cilium`
        # import below stands for it. The `cilium` instance uses it (no
        # chart, no HelmChartConfig), claims the enforcer role, and emits the
        # CRD references the generated policies wait on.
        cluster.roles = {
          cni = {
            binding = "shadowable";
            provider = "cilium (environment)";
          };
          loadBalancer.binding = "absent";
          # local-path-provisioner is installed with the target; the
          # `platform-storage` import below names its class.
          storageClasses.binding = "shadowable";
        };

        instances.ingress-system = {
          cilium = {
            package = packages.experimental.cilium;
          };
          platform-cilium.package = kix.mkImport {
            roles = [ "cni" ];
            out.helmChartConfig = null;
          };
          # `kind`, `apiVersion`, and `out.name` make the deploy wait for the
          # StorageClass, and let the claims that name it resolve in the
          # cluster build.
          platform-storage = {
            package = kix.mkImport {
              roles = [ "storageClasses" ];
              kind = "StorageClass";
              apiVersion = "storage.k8s.io/v1";
              out = {
                name = "local-path";
                storageClassName = "local-path";
              };
            };
          };
          platform-dns = {
            package = kix.mkImport {
              roles = [ "dns" ];
              out = {
                name = "coredns";
                fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
              };
            };
          };
          ingress-nginx = {
            package = packages.experimental."ingress-nginx";
          };
        };

        # A namespace of its own: the rule has to cross one, which is the
        # case a same-namespace fallback would hide.
        instances.files = {
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files.lt.test";
          };
          filebrowser-data = {
            package = packages."persistent-volume-claim";
            aliases = [ "storage" ];
            config = {
              size = "1Gi";
              storageClassName = "local-path";
            };
          };
        };
      }
    )
  ];
}
