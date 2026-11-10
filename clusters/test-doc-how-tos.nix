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
      { ref, ... }:
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

        # A Secret created outside Kix that holds the Cloudflare API token
        # under the key `api-token`.
        instances.cert-manager.cloudflare-api-token = {
          package = packages.secret-ref;
          config.keys = [ "api-token" ];
        };

        instances.cert-manager.letsencrypt = {
          package = packages.cluster-issuer;
          deps.issuerCredentials = ref.cert-manager.cloudflare-api-token;
          config.spec.acme = {
            server = "https://acme-v02.api.letsencrypt.org/directory";
            email = "platform@example.com";
            solvers = [
              {
                dns01.cloudflare.apiTokenSecretRef.key = "api-token";
                selector.dnsZones = [ "example.com" ];
              }
            ];
          };
        };
        # endregion:acmeClusterIssuer

        # region:stagingClusterIssuer
        instances.cert-manager.letsencrypt-staging = {
          package = packages.cluster-issuer;
          # An empty list replaces the default alias `clusterIssuer`, so
          # only the production issuer answers it.
          aliases = [ ];
          deps.issuerCredentials = ref.cert-manager.cloudflare-api-token;
          config.spec.acme = {
            server = "https://acme-staging-v02.api.letsencrypt.org/directory";
            email = "platform@example.com";
            solvers = [
              {
                dns01.cloudflare.apiTokenSecretRef.key = "api-token";
                selector.dnsZones = [ "example.com" ];
              }
            ];
          };
        };
        # endregion:stagingClusterIssuer

        # region:importedClusterIssuer
        instances.external-tls.cluster-issuer = {
          package = kix.mkImport {
            out.withCert =
              args:
              args
              // {
                annotations = (args.annotations or { }) // {
                  "cert-manager.io/cluster-issuer" = "letsencrypt";
                };
              };
          };
          aliases = [ "clusterIssuer" ];
        };
        # endregion:importedClusterIssuer

        # The managed `letsencrypt` issuer also answers `clusterIssuer`, and
        # DI prefers a managed instance over an import, so this consumer
        # names the import.
        instances.external-tls.web = {
          package = webPackage;
          config.ingress.host = "imported.example.com";
          deps.clusterIssuer = ref.external-tls.cluster-issuer;
        };

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
