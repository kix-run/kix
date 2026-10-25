# clusters/test-bundle-alias.nix: an instance that names one resource under
# two parts.
#
# `kix bundle` must write and read back a build like this.
#
# Build:  nix build .#cluster-bundle-alias

{ kix, packages }:

let
  aliasedPackage = {
    meta.version = "0.0.0";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "twice";
          data.k = "v";
        };
        alias = self.cm;
        root = self.cm;
      };
  };
in
kix.buildCluster {
  name = "test-bundle-alias";
  modules = [
    {
      namespaces.kube-system = { };
      namespaces.app = { };

      instances.kube-system.coredns = {
        package = packages.coredns;
        config.clusterIP = "10.96.0.10";
      };

      instances.app.twice.package = aliasedPackage;
    }
  ];
}
