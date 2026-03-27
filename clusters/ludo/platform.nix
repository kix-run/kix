# Platform — infra that needs explicit config on this cluster.
# Everything with acceptable defaults auto-instantiates via availablePackages.

{
  config,
  lib,
  packages,
  ...
}:
{
  options = {
    cluster.domain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain for the cluster";
    };

    tls.clusterIssuer = lib.mkOption {
      type = lib.types.str;
      default = "letsencrypt-staging";
    };
  };

  config.instances = {

    # k3s provides local-path-provisioner; this satisfies the storageClasses DI dep.
    kube-system.storage-classes = {
      package = {
        meta.defaultAliases = [ "storageClasses" ];
        build =
          { scope, ... }:
          {
            root = scope.mkResource {
              apiVersion = "storage.k8s.io/v1";
              kind = "StorageClass";
              name = "local-path";
              extra = {
                provisioner = "rancher.io/local-path";
                reclaimPolicy = "Delete";
                volumeBindingMode = "WaitForFirstConsumer";
              };
              annotations."storageclass.kubernetes.io/is-default-class" = "true";
              outputs.storageClassName = "local-path";
            };
          };
      };
    };

    # TLS issuers — just scope to our domain
    cert-manager.cluster-issuers = {
      package = packages.cluster-issuers;
      config = {
        mainIssuer = config.tls.clusterIssuer;
        issuers.letsencrypt-staging.dnsZones = [ config.cluster.domain ];
        issuers.letsencrypt-production.dnsZones = [ config.cluster.domain ];
      };
    };

  };
}
