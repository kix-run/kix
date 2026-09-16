# Evaluated examples for the platform capability how-to guides.

{ kix, packages }:

let
  # region:managedStorageClassPackage
  storageProvider =
    { scope, ... }:
    {
      meta = {
        version = "1.0.0";
        description = "Default StorageClass for the documentation example";
        roles = [ "storageClasses" ];
      };

      build =
        { self, ... }:
        {
          storageClass = scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            name = "example-local";
            extra = {
              provisioner = "kubernetes.io/no-provisioner";
              volumeBindingMode = "WaitForFirstConsumer";
            };
          };

          root = {
            resource = self.storageClass;
            out.storageClassName = self.storageClass.out.name;
          };
        };
    };
  # endregion:managedStorageClassPackage

  webPackage =
    { scope, kix, ... }:
    {
      meta = {
        version = "1.0.0";
        description = "Web application for the TLS documentation example";
      };

      options.ingress = kix.options.ingress;

      build = [
        (
          { self, ... }:
          {
            deployment = scope.mkDeployment {
              name = scope.instanceName;
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template.spec.containers = [
                  {
                    name = "web";
                    image = "docker.io/library/nginx:1.27-alpine";
                    ports = [ (kix.port "http" 80) ];
                  }
                ];
              };
            };

            service =
              self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;

            root = self.service;
          }
        )
        (kix.expose { service = "service"; })
      ];
    };
in
kix.buildCluster {
  name = "doc-how-tos";
  specialArgs = { inherit packages kix; };

  modules = [
    kix.flavors.kind
    (
      { lib, ... }:
      {
        # region:shadowPlatformStorage
        instances.storage-system.storage = {
          package = storageProvider;
        };
        # endregion:shadowPlatformStorage

        # region:configuredPersistentVolumeClaim
        instances.apps.data = {
          package = packages."persistent-volume-claim";
          config = {
            size = "20Gi";
            accessModes = [ "ReadWriteOnce" ];
            # Omit storageClassName to use the storageClasses provider.
          };
        };
        # endregion:configuredPersistentVolumeClaim

        instances.ingress-system."ingress-nginx" = {
          package = packages."ingress-nginx";
        };

        # region:acmeClusterIssuer
        instances.cert-manager.cert-manager = {
          package = packages.cert-manager;
        };

        instances.cert-manager.cluster-issuers = {
          package = packages."cluster-issuers";
          config = {
            mainIssuer = "letsencrypt-production";
            issuers = lib.mkForce {
              letsencrypt-production = {
                kind = "acme";
                server = "https://acme-v02.api.letsencrypt.org/directory";
                email = "platform@example.com";
                privateKeySecretName = "letsencrypt-production-account";
                cloudflareSecret = {
                  name = "cloudflare-api-token";
                  key = "api-token";
                };
                dnsZones = [ "example.com" ];
              };
            };
          };
        };
        # endregion:acmeClusterIssuer

        # region:tlsApplicationInstance
        instances.apps.web = {
          package = webPackage;
          config.ingress.host = "web.example.com";
        };
        # endregion:tlsApplicationInstance
      }
    )
  ];
}
