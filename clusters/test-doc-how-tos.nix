# Evaluated examples for the platform capability how-to guides.

{ kix, packages }:

let
  # region:managedStorageClassPackage
  storageProvider =
    { scope, ... }:
    {
      meta = {
        description = "StorageClass for the documentation example";
        owner = "platform";
        roles = [ "storageClasses" ];
      };

      build =
        { self, ... }:
        {
          storageClass = scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            name = "local-path-retain";
            extra = {
              provisioner = "rancher.io/local-path";
              reclaimPolicy = "Retain";
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
                    image = "docker.io/nginxinc/nginx-unprivileged:1.27-alpine";
                    securityContext.runAsNonRoot = true;
                    ports = [ (kix.port "http" 8080) ];
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
      { lib, ref, ... }:
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

        # region:externalDnsInstance
        instances.external-dns = {
          # A Secret created outside Kix that holds the Cloudflare API
          # token under the key `api-token`.
          cloudflare-api-token = {
            package = packages.secret-ref;
            config.keys = [ "api-token" ];
          };

          external-dns = {
            package = packages.external-dns;
            deps.providerCredentials = ref.external-dns.cloudflare-api-token;
            config = {
              provider = "cloudflare";
              policy = "upsert-only";
              txtOwnerId = "production/external-dns";
              sources = [
                "service"
                "ingress"
                "gateway-httproute"
              ];
              secretEnv.CF_API_TOKEN = "api-token";
              extraArgs = [ "--domain-filter=example.com" ];
            };
          };
        };
        # endregion:externalDnsInstance

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
