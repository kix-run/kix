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

        # region:importedPostgresDatabase
        instances.contracts-rds = {
          rds-login = {
            package = packages.secret-ref;
            config.keys = [
              "username"
              "password"
            ];
          };

          database.package = kix.mkImport {
            scope = "namespace";
            out = {
              host = "app.abc123.eu-west-1.rds.amazonaws.com";
              port = "5432";
              database = "metabase";
              tls = true;
              credentials = ref.contracts-rds.rds-login;
            };
          };

          encryption-key = {
            package = packages.secret-ref;
            aliases = [ "encryptionKey" ];
            config.keys = [ "key" ];
          };

          metabase.package = packages.metabase;
        };
        # endregion:importedPostgresDatabase

        # region:importedRedisCache
        instances.contracts-redis = {
          redis-login = {
            package = packages.secret-ref;
            config.keys = [ "password" ];
          };

          valkey.package = kix.mkImport {
            scope = "namespace";
            out = {
              host = "app-cache.abc123.euw1.cache.amazonaws.com";
              port = "6379";
              tls = true;
              credentials = ref.contracts-redis.redis-login;
            };
          };
          # endregion:importedRedisCache

          n8n-db-login = {
            package = packages.secret-ref;
            config.keys = [
              "username"
              "password"
            ];
          };

          database.package = kix.mkImport {
            scope = "namespace";
            out = {
              host = "n8n.abc123.eu-west-1.rds.amazonaws.com";
              port = "5432";
              database = "n8n";
              tls = true;
              credentials = ref.contracts-redis.n8n-db-login;
            };
          };

          encryption-key = {
            package = packages.secret-ref;
            aliases = [ "encryptionKey" ];
            config.keys = [ "key" ];
          };

          n8n.package = packages.n8n;
        };

        # region:clusterWideSmtpRelay
        instances.mail.smtp.package = kix.mkImport {
          out = {
            host = "relay.internal.example.org";
            port = "587";
            tls = "starttls";
            from = "noreply@example.org";
          };
        };
        # endregion:clusterWideSmtpRelay

        instances.vault = {
          storage = {
            package = packages.persistent-volume-claim;
            config.size = "2Gi";
          };

          vault-db-login = {
            package = packages.secret-ref;
            config.keys = [
              "username"
              "password"
            ];
          };

          database.package = kix.mkImport {
            scope = "namespace";
            out = {
              host = "vault.abc123.eu-west-1.rds.amazonaws.com";
              port = "5432";
              database = "vaultwarden";
              tls = true;
              credentials = ref.vault.vault-db-login;
            };
          };

          # region:authenticatedSmtpImport
          smtp-login = {
            package = packages.secret-ref;
            config.keys = [
              "username"
              "password"
            ];
          };

          smtp.package = kix.mkImport {
            scope = "namespace";
            out = {
              host = "smtp.mailgun.org";
              port = "465";
              tls = "implicit";
              from = "alerts@example.org";
              credentials = ref.vault.smtp-login;
            };
          };

          vaultwarden = {
            package = packages.vaultwarden;
            config = {
              domain = "https://vault.example.org";
              mail.from = "vault@example.org";
            };
          };
          # endregion:authenticatedSmtpImport
        };

        # region:keycloakOidcProvider
        instances.auth.keycloak.package = kix.mkImport {
          out = {
            issuerUrl = realm: "https://sso.example.org/realms/${realm}";
            endpoints = realm: {
              authorizationUrl = "https://sso.example.org/realms/${realm}/protocol/openid-connect/auth";
              tokenUrl = "https://sso.example.org/realms/${realm}/protocol/openid-connect/token";
              userinfoUrl = "https://sso.example.org/realms/${realm}/protocol/openid-connect/userinfo";
            };
          };
        };
        # endregion:keycloakOidcProvider

        instances.monitoring = {
          grafana-storage = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "2Gi";
          };

          grafana-admin = {
            package = packages.secret-ref;
            aliases = [ "grafanaAdmin" ];
            config.keys = [
              "admin-user"
              "admin-password"
            ];
          };

          # region:keycloakOidcClient
          grafana-oidc = {
            package = packages.secret-ref;
            aliases = [ "oidcClient" ];
            config.keys = [
              "clientId"
              "clientSecret"
            ];
          };

          oidc = {
            package = packages.oidc-client;
            deps.oidcProvider = ref.auth.keycloak;
            config.realm = "main";
          };

          grafana = {
            package = packages.grafana;
            config = {
              ingress.host = "grafana.example.org";
              oidc.autoLogin = true;
            };
          };
          # endregion:keycloakOidcClient
        };

        # region:externalOidcImport
        instances.photos = {
          immich-oidc = {
            package = packages.secret-ref;
            config.keys = [
              "clientId"
              "clientSecret"
            ];
          };

          oidc.package = kix.mkImport {
            scope = "namespace";
            out = {
              issuerUrl = "https://login.example.org";
              credentials = ref.photos.immich-oidc;
            };
          };
        };
        # endregion:externalOidcImport
      }
    )
  ];
}
