# clusters/test-ingress-netpol.nix — the ingress controller to backend edge.
#
# The smallest cluster that shows the edge: a controller in one namespace,
# an exposed backend in another, default-deny network policy on. Under
# cilium the backend's pods accept nothing they have no ingress rule for,
# and the controller is a pod like any other, so without a rule naming it
# every request through the Ingress ends as a 504 the compiler cannot see.
# filebrowser is the backend because it is one Deployment, one Service and
# one `kix.expose`, and nothing else.
#
# Build:  nix build .#cluster-ingress-netpol --extra-experimental-features pipe-operators
#
# It is meant to be deployed, against a cluster that already runs cilium
# (the lithus test targets do). It takes no flavor on purpose: a flavor
# declares platform instances in `kube-system`, every declared namespace
# gets a default-deny policy, and denying kube-system by default on a
# cluster kix did not build takes out that cluster's own DNS. Everything
# here lives in namespaces this fixture creates.

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

        # cilium is installed by the target, not by kix. The marker
        # package claims the enforcer role and emits the CRD reference
        # the generated policies wait on.
        cluster.roles = {
          cni = {
            binding = "exclusive";
            provider = "cilium (rke2-managed)";
          };
          loadBalancer.binding = "absent";
          # Filled by the import below. Left to itself the graph
          # auto-instantiates the stock StorageClass catalogue, which
          # would arrive on this cluster claiming to be its default
          # class, and neither an "absent" binding nor a claim that
          # names its class outright stops that.
          storageClasses.binding = "shadowable";
        };

        instances.ingress-system = {
          cilium = {
            package = packages."cilium-external";
          };
          # No `kind`/`apiVersion`: those make the deploy verify the
          # import against the cluster, and it looks for a namespaced
          # object. The role and the class name are all this needs to
          # carry.
          platform-storage = {
            package = kix.mkImport {
              roles = [ "storageClasses" ];
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
            package = packages."ingress-nginx";
          };
        };

        # A namespace of its own: the rule has to cross one, which is the
        # case a same-namespace fallback would hide.
        instances.files = {
          filebrowser = {
            package = packages.filebrowser;
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
