# Vaultwarden — self-hosted Bitwarden-compatible password manager.
#
# Runs with SQLite by default (simplest). Can optionally use Postgres via DI.
# Data is persisted via a storage PVC dependency.
#
# Dependencies:
#   storage        — required, persistent volume for SQLite DB + attachments
#   postgres       — optional, uses Postgres instead of SQLite when present
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
        scope,
        kix,
        postgres ? null,
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
        usePostgres = postgres != null;

        healthCheck = {
          httpGet = {
            path = "/alive";
            port = "http";
          };
          periodSeconds = 10;
          timeoutSeconds = 1;
        };

        # Database URL: Postgres if injected, else SQLite in the data volume.
        databaseUrl =
          if usePostgres then
            "postgresql://vaultwarden:vaultwarden@${postgres.out.fqdn}:${postgres.out.port}/vaultwarden"
          else
            "/data/db.sqlite3";
      in
      {
        deployment =
          {
            name = name;
            spec = {
              replicas = 1;
              strategy.type = "Recreate"; # SQLite can't handle concurrent writers
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                containers = [
                  {
                    name = "vaultwarden";
                    image = "${config.image.repository}:${config.image.tag}";
                    ports = [ (kix.port "http" 8080) ];
                    env = kix.mkEnvVars (
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
