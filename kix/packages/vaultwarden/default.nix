# Vaultwarden: self-hosted Bitwarden-compatible password manager.
#
# Uses Postgres via DI. Attachments persisted on a storage PVC.
#
# Dependencies:
#   storage          required, persistent volume for attachments/icons
#   postgres         required, database (expects stackgres-style credentials
#                    secret exposed via `out.superuserSecret`)
#
# Exposure handled by kix.expose (ingress or gateway via DI). DOMAIN
# defaults to the URL of that route.
#
# root = Service (port 8080).

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;

  # init-chown-data runs as root. When security.nonRoot would fail the
  # build, fail it here instead with the override that lets the migration
  # deploy through.
  chownOverrideHint = "initChownData adds the root init container init-chown-data, which fails the security.nonRoot scorecard rule. For the migration deploy, set scorecard.ruleOverrides.byNamespace.${scope.namespaceName}.\"security.nonRoot\".severity = \"warning\" in the cluster definition. Once the pod has started, remove that override and set initChownData = false.";
  nonRootFailsBuild =
    clusterConfig:
    kix.scorecard.effectiveSeverity {
      inherit clusterConfig;
      rule = "security.nonRoot";
      namespaceName = scope.namespaceName;
      owner = "app-team";
    } == "error";
in
{
  meta = {
    version = "1.36.0";
    description = "Vaultwarden: Bitwarden-compatible password manager";
    owner = "app-team";
  };

  # Printed on the build that passes too, as the reminder to undo the
  # override afterwards.
  warnings =
    { config, ... }:
    lib.optional config.initChownData chownOverrideHint;

  options = {
    image = kix.options.image {
      repository = "vaultwarden/server";
      tag = "1.36.0-alpine";
      pullPolicy = null;
    };
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public URL (e.g. https://vault.example.com). Default: the URL kix.expose routes (exposure.url). Set it when TLS terminates outside Kix, for example behind cloudflared.";
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
    # The guerzon/vaultwarden chart sets no resources; these are the values
    # its values.yaml suggests.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "50m";
          memory = "256Mi";
        };
        limits = {
          cpu = "300m";
          memory = "1Gi";
        };
      };
    };
    ingress = kix.options.ingress;
    adminToken = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Argon2 hash for admin panel access. Null disables admin panel.";
    };
    initChownData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run `chown -R 1001:1001 /data` as root in an init container before
        Vaultwarden starts. Vaultwarden runs as uid 1001, and fsGroup does
        not change ownership on hostPath or local-path volumes, so a volume
        written by an earlier root-run release stays unwritable. Enable
        this for the first deploy after such an upgrade. The init container
        fails the `security.nonRoot` scorecard rule, so that deploy also
        needs `scorecard.ruleOverrides.byNamespace.<namespace>."security.nonRoot".severity = "warning"`.
        Remove both once the pod has started.
      '';
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

        dataMount = kix.mount.pvc storage { mountPath = "/data"; };
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
                # Kubernetes default: Rocket's own shutdown grace is a few
                # seconds.
                terminationGracePeriodSeconds = 30;
                # The image defines no user. uid 1001 and the fsGroup follow
                # the guerzon/vaultwarden chart's suggested security context;
                # fsGroup makes the data volume writable on provisioners that
                # honour it, and OnRootMismatch skips the recursive relabel
                # once the volume root already has that group.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 1001;
                  runAsGroup = 1001;
                  fsGroup = 1001;
                  fsGroupChangePolicy = "OnRootMismatch";
                };
                ${if config.initChownData then "initContainers" else null} = lib.singleton (
                  if nonRootFailsBuild clusterConfig then
                    throw "${name}: ${chownOverrideHint}"
                  else
                    {
                      name = "init-chown-data";
                      image = "docker.io/library/busybox:1.38.0";
                      command = [
                        "chown"
                        "-R"
                        "1001:1001"
                        dataMount.mountPath
                      ];
                      securityContext = {
                        runAsNonRoot = false;
                        runAsUser = 0;
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities = {
                          add = [ "CHOWN" ];
                          drop = [ "ALL" ];
                        };
                      };
                      volumeMounts = [ { inherit (dataMount) name mountPath; } ];
                    }
                );
                containers = [
                  (
                    {
                      name = "vaultwarden";
                      image = kix.image.ref config.image;
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
                            DOMAIN = if config.domain != null then config.domain else self.exposure.url;
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
                      resources = config.resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                      };
                    }
                    // lib.optionalAttrs (config.image.pullPolicy != null) {
                      imagePullPolicy = config.image.pullPolicy;
                    }
                  )
                ];
              };
            };
          }
          |> kix.withMounts [
            dataMount
          ]
          |> scope.mkDeployment;

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
