# vaultwarden: Vaultwarden, a Bitwarden-compatible password manager
# server, on PostgreSQL.
#
# Installs a Deployment and a Service on port 8080, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway.
# Vaultwarden's `DOMAIN` is the route's URL unless `domain` is set.
#
# Dependencies:
#   storage (required)    a claim, mounted at /data, for attachments, icons,
#                         and keys
#   database (required)   a PostgreSQL database and role honouring the
#                         Postgres database contract
#                         (kix.contracts.postgresDatabase), such as
#                         stackgres-database
#   smtp (optional)       a mail server honouring the SMTP contract
#                         (kix.contracts.smtp), usually a kix.mkImport, for
#                         invitations, verification, and alerts
#
# Minimal instance, with a stackgres-cluster `postgres` elsewhere:
#
#   instances.vault = {
#     storage = {
#       package = packages.persistent-volume-claim;
#       config.size = "1Gi";
#     };
#     vaultwarden-db = {
#       package = packages.stackgres-database;
#       config.passwordSource = ./secrets/vaultwarden-db.yaml;
#       config.passwordHash = "...";
#     };
#     vaultwarden.package = packages.vaultwarden;   # takes deps.storage
#   };                                              # and deps.database
#
# Mail: with `smtp` wired, the package sets SMTP_HOST, SMTP_PORT,
# SMTP_SECURITY (`starttls`, `force_tls` for implicit TLS, or `off`),
# SMTP_FROM (the server's `out.from`, or `mail.from`), and the login from
# its `out.credentials`, and refuses them in `env`. Vaultwarden refuses to
# send when the server does not offer STARTTLS. A server outside the cluster gets
# egress to any address on its port, because the network policy cannot name
# a host outside the cluster.
#
# `out`: the Service's `name`, `fqdn`, and `port` (8080).
#
# Escape hatches: `env` for Vaultwarden settings (signups, invitations,
# ADMIN_TOKEN), `ingress` for the route, and the instance's `partsOverlays`.
#
# Limits: one replica with the Recreate strategy. The database password goes
# into DATABASE_URL unescaped, so it must not contain URL delimiters such as
# `@`, `/`, or `:`.

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

  deps.database.assertions =
    dep: kix.contracts.postgresDatabase.assertions "vaultwarden ${scope.namespaceName}/${name}" dep;

  # Printed on the build that passes too, as the reminder to undo the
  # override afterwards.
  warnings = { config, ... }: lib.optional config.initChownData chownOverrideHint;

  options = {
    image = kix.options.image {
      repository = "vaultwarden/server";
      tag = "1.36.0-alpine";
      pullPolicy = null;
    };
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public URL (e.g. https://vault.example.com), which invitation links and WebAuthn need. Default: the URL kix.expose routes (exposure.url); evaluation fails when Kix cannot derive one. Set it when TLS terminates outside Kix, for example behind cloudflared.";
    };
    env = kix.options.env // {
      description = "Extra Vaultwarden environment variables (Vaultwarden's `.env.template` lists them). A value is a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The package sets SIGNUPS_ALLOWED = \"false\", INVITATIONS_ALLOWED = \"true\", and SHOW_PASSWORD_HINT = \"false\"; a value here replaces them and null removes them. ADMIN_TOKEN turns on the admin panel; give it the token's Argon2 hash, from a Secret. The package owns the database, address, and data folder variables.";
    };
    # The guerzon/vaultwarden chart sets no resources; these are the values
    # its values.yaml suggests.
    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "256Mi";
      };
      limits = {
        cpu = "300m";
        memory = "1Gi";
      };
    };
    ingress = kix.options.ingress;
    mail = kix.contracts.smtp.options;
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
        database,
        smtp ? null,
        scope,
        kix,
        ...
      }:
      let
        relay = kix.contracts.smtp.helpers.settings {
          who = "vaultwarden ${scope.namespaceName}/${name}";
          inherit smtp;
          inherit (config.mail) from;
        };

        healthCheck = {
          httpGet = {
            path = "/alive";
            port = "http";
          };
          periodSeconds = 10;
          timeoutSeconds = 1;
        };

        # DB_USERNAME and DB_PASSWORD come from the database's credentials
        # Secret; Kubernetes substitutes $(VAR) from variables defined
        # earlier in the list. toString lets an integer port reach the
        # contract assertion, which names it, instead of failing here.
        databaseUrl = "postgresql://$(DB_USERNAME):$(DB_PASSWORD)@${database.out.host}:${toString database.out.port}/${database.out.database}";

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
              # A changed database password restarts the pods, which read it
              # once at start. A Secret Kix does not build has no hash.
              template.metadata.annotations =
                lib.optionalAttrs (database.out.credentials.out ? identityHash) {
                  "checksum/database" = database.out.credentials.out.identityHash;
                }
                //
                  lib.optionalAttrs
                    (relay != null && relay.credentials != null && relay.credentials.out ? identityHash)
                    {
                      "checksum/smtp" = relay.credentials.out.identityHash;
                    };
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
                    }
                );
                containers = [
                  (
                    {
                      name = "vaultwarden";
                      image = kix.image.ref config.image;
                      ports = [ (kix.port "http" 8080) ];
                      env =
                        (database.out.credentials.out.mkEnv {
                          DB_USERNAME = "username";
                          DB_PASSWORD = "password";
                        })
                        ++ kix.mkEnvVars (
                          kix.mergeEnv {
                            who = "vaultwarden ${scope.namespaceName}/${name}";
                            defaults = {
                              SIGNUPS_ALLOWED = "false";
                              INVITATIONS_ALLOWED = "true";
                              SHOW_PASSWORD_HINT = "false";
                            };
                            owned = [
                              {
                                vars.DATABASE_URL = databaseUrl;
                                names = [
                                  "DB_USERNAME"
                                  "DB_PASSWORD"
                                ];
                                from = "the database dependency";
                                fix = "Wire another database through deps.database instead.";
                              }
                              {
                                vars.DOMAIN = if config.domain != null then config.domain else self.exposure.url;
                                from = "the `domain` option or the instance's route";
                                fix = "Set `domain` instead.";
                              }
                              {
                                vars.DATA_FOLDER = dataMount.mountPath;
                                from = "the storage dependency, which the package mounts at ${dataMount.mountPath}";
                                fix = "Remove it.";
                              }
                            ]
                            ++ lib.optional (relay != null) {
                              vars = {
                                SMTP_HOST = relay.host;
                                SMTP_PORT = relay.port;
                                SMTP_SECURITY =
                                  {
                                    starttls = "starttls";
                                    implicit = "force_tls";
                                    none = "off";
                                  }
                                  .${relay.tls};
                                SMTP_FROM = relay.from;
                              }
                              // lib.optionalAttrs (relay.credentials != null) {
                                SMTP_USERNAME = relay.credentials.out.keyRef "username";
                                SMTP_PASSWORD = relay.credentials.out.keyRef "password";
                              };
                              names = [
                                "SMTP_USERNAME"
                                "SMTP_PASSWORD"
                                "SMTP_USERNAME_FILE"
                                "SMTP_PASSWORD_FILE"
                                "USE_SENDMAIL"
                              ];
                              from = "the smtp dependency";
                              fix = "Wire another SMTP instance through deps.smtp, or set mail.from.";
                            }
                            ++ [
                              {
                                vars = {
                                  ROCKET_ADDRESS = "0.0.0.0";
                                  ROCKET_PORT = "8080";
                                };
                                from = "the package, whose probes and Service use port 8080";
                                fix = "Remove it.";
                              }
                            ];
                          } config.env
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
          |> kix.withMountsOn ([ "vaultwarden" ] ++ lib.optional config.initChownData "init-chown-data") [
            dataMount
          ]
          |> scope.mkDeployment;

        mailEgress = kix.contracts.smtp.helpers.egressPolicy {
          inherit scope;
          smtp = relay;
          name = "${name}-mail-egress";
          selector = self.deployment.out.selector;
        };

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
