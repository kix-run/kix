# Vaultwarden — self-hosted Bitwarden-compatible password manager.
#
# Uses Postgres via DI. Attachments persisted on a storage PVC.
#
# Dependencies:
#   storage        — required, persistent volume for attachments/icons
#   postgres       — required, database (expects stackgres-style credentials
#                    secret exposed via `out.superuserSecret`)
#
# Exposure handled by kix.expose (ingress via DI).
#
# root = Service (port 8080).

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "1.35.4";
    description = "Vaultwarden — Bitwarden-compatible password manager";
    provides = [ "password-manager" ];
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "vaultwarden/server";
        tag = "1.35.4-alpine";
      };
    };
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public URL (e.g. https://vault.example.com). Required for clients to connect.";
    };
    signupsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    invitationsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    showPasswordHint = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables (SCREAMING_SNAKE_CASE).";
    };
    ingress = kix.options.ingress;
    adminToken = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Argon2 hash for admin panel access. Null disables admin panel.";
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        storage,
        postgres,
        scope,
        kix,
        ...
      }:
      let
        clusterDomain = clusterConfig.cluster.domain or null;
        effectiveHost =
          if config.ingress.host != null then
            config.ingress.host
          else if clusterDomain != null then
            "${name}.${clusterDomain}"
          else
            null;

        healthCheck = {
          httpGet = {
            path = "/alive";
            port = "http";
          };
          periodSeconds = 10;
          timeoutSeconds = 1;
        };

        # Credentials come from stackgres' superuser secret via env var
        # substitution ($(VAR) syntax). Until we create a dedicated
        # vaultwarden role/db, connect with the superuser to the default
        # `postgres` database.
        databaseUrl = "postgresql://$(DB_USERNAME):$(DB_PASSWORD)@${postgres.out.fqdn}:${postgres.out.port}/postgres";
      in
      {
        deployment =
          {
            name = name;
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                containers = [
                  {
                    name = "vaultwarden";
                    image = "${config.image.repository}:${config.image.tag}";
                    ports = [ (kix.port "http" 8080) ];
                    env =
                      # Secret refs FIRST so k8s can substitute $(DB_USERNAME)/$(DB_PASSWORD)
                      # in DATABASE_URL. K8s only substitutes vars defined earlier in the list.
                      (postgres.out.superuserSecret.out.mkEnv {
                        DB_USERNAME = "superuser-username";
                        DB_PASSWORD = "superuser-password";
                      })
                      ++ kix.mkEnvVars (
                        {
                          DATA_FOLDER = "/data";
                          DATABASE_URL = databaseUrl;
                          DOMAIN =
                            if config.domain != null then
                              config.domain
                            else if effectiveHost != null then
                              "https://${effectiveHost}"
                            else
                              null;
                          SIGNUPS_ALLOWED = lib.boolToString config.signupsAllowed;
                          INVITATIONS_ALLOWED = lib.boolToString config.invitationsAllowed;
                          SHOW_PASSWORD_HINT = lib.boolToString config.showPasswordHint;
                          ROCKET_ADDRESS = "0.0.0.0";
                          ROCKET_PORT = "8080";
                          ADMIN_TOKEN = config.adminToken;
                        }
                        // config.env
                      );
                    livenessProbe = healthCheck // {
                      initialDelaySeconds = 5;
                      failureThreshold = 10;
                    };
                    readinessProbe = healthCheck // {
                      initialDelaySeconds = 5;
                      failureThreshold = 3;
                    };
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.pvc storage { mountPath = "/data"; })
          ]
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
