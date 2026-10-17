# Firezone: self-hosted WireGuard VPN server with web UI.
#
# Based on BeanVPN/firezone-helm-chart. Every credential is a secret
# dependency, so the package renders no Secret of its own and the site
# chooses where each value comes from (a SOPS file, a secrets operator, or
# `stringData` in a test cluster).
#
# Dependencies:
#   database (required)            a postgres-database contract (a
#                                  stackgres-database or cnpg-database
#                                  instance): host, port, database name, and
#                                  credentials with `username` and
#                                  `password`. The package asks the database
#                                  for the pgcrypto, btree_gist, and citext
#                                  extensions.
#   applicationSecrets (required)  a secret with the keys
#                                  GUARDIAN_SECRET_KEY, SECRET_KEY_BASE, and
#                                  DATABASE_ENCRYPTION_KEY, and optionally
#                                  LIVE_VIEW_SIGNING_SALT, COOKIE_SIGNING_SALT,
#                                  and COOKIE_ENCRYPTION_SALT. Each key is
#                                  the Firezone environment variable of the
#                                  same name; a salt the secret does not
#                                  declare is left unset.
#   adminPassword (required)       a secret with the key `password`, the
#                                  default administrator's password
#                                  (DEFAULT_ADMIN_PASSWORD); `admin.email`
#                                  is the login.
#   wireguardKey (required)        a secret with the key `private_key`, the
#                                  server's WireGuard private key
#                                  (`wg genkey`), mounted as a file.
#   samlCertificate (optional)     a secret with the keys `saml.crt` and
#                                  `saml.key` (PEM). Without it the image
#                                  generates a self-signed pair.
#   reloader (optional)            restarts the pod when a `secret-ref`
#                                  dependency changes. A Kix-built secret
#                                  rolls the pod through a checksum
#                                  annotation without it.
#
# Minimal instance, with a stackgres-cluster `postgres` elsewhere
# (`clusters/test-immich.nix` evaluates this shape with `stringData`):
#
#   instances.vpn = {
#     firezone = {
#       package = packages.firezone;
#       config = {
#         domain = "vpn.example.com";
#         admin.email = "admin@example.com";
#       };
#     };
#     firezone-db = { package = packages.stackgres-database; config.passwordSource = ./secrets/firezone-db.yaml; config.passwordHash = "..."; };
#     firezone-secrets = {
#       package = packages.secret;
#       aliases = [ "applicationSecrets" ];
#       config.keys = [ "GUARDIAN_SECRET_KEY" "SECRET_KEY_BASE" "DATABASE_ENCRYPTION_KEY" ];
#       config.source = ./secrets/firezone-app.yaml;
#     };
#     firezone-admin = { package = packages.secret; aliases = [ "adminPassword" ]; config.keys = [ "password" ]; config.source = ./secrets/firezone-admin.yaml; };
#     firezone-wireguard = { package = packages.secret; aliases = [ "wireguardKey" ]; config.keys = [ "private_key" ]; config.source = ./secrets/firezone-wg.yaml; };
#   };
#
# Exposure: uses kix.expose (port 13000) for optional ingress/TLS.
#
# Resources: ConfigMap (env), Deployment, Service.
#
# root = Service (port 13000 http + 51820 wireguard/UDP).

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  who = "firezone ${scope.namespaceName}/${name}";
in
{
  meta = {
    version = "0.7.26";
    description = "Firezone: self-hosted WireGuard VPN";
    owner = "app-team";
    # One process owns the WireGuard interface and its peer state, so
    # Firezone 0.7 cannot run more than one replica.
    availability.max = "none";
    # init-sysctl sets net.ipv4.ip_forward, which needs a privileged
    # container; the WireGuard gateway image itself runs as root.
    unsafe = [
      "run-as-root"
      "privileged"
    ];
  };

  # Firezone's migrations run CREATE EXTENSION for these three, and
  # StackGres installs an extension on the postgres image only when the
  # SGCluster lists it; the database facade forwards them to its cluster.
  deps.database.config.extensions = [
    { name = "pgcrypto"; }
    { name = "btree_gist"; }
    { name = "citext"; }
  ];
  deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;

  options = {
    image = kix.options.image {
      repository = "firezone/firezone";
      tag = "0.7.26";
    };

    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Pinned to one at every level: see meta.availability.max.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 1;
        zone = 1;
      };
      description = ''
        Number of Firezone replicas. Pinned to one at every availability
        level (v2_discussions/145) because the WireGuard interface has a
        single owner.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain for Firezone (used in EXTERNAL_URL and DEFAULT_CLIENT_ENDPOINT)";
    };

    wireguard = lib.mkOption {
      type = lib.types.submodule {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 51820;
            description = "UDP port of the WireGuard interface, also advertised to clients.";
          };
          ipv4Network = lib.mkOption {
            type = lib.types.str;
            default = "100.64.0.0/10";
            description = "IPv4 network that client addresses are allocated from.";
          };
          ipv4Address = lib.mkOption {
            type = lib.types.str;
            default = "100.64.0.1";
            description = "IPv4 address of the server on the WireGuard interface.";
          };
          ipv6Network = lib.mkOption {
            type = lib.types.str;
            default = "fd00::/106";
            description = "IPv6 network that client addresses are allocated from.";
          };
          ipv6Address = lib.mkOption {
            type = lib.types.str;
            default = "fd00::1";
            description = "IPv6 address of the server on the WireGuard interface.";
          };
        };
      };
      default = { };
      description = "WireGuard interface settings. The private key is the `wireguardKey` dependency.";
    };

    admin = lib.mkOption {
      type = lib.types.submodule {
        options = {
          email = lib.mkOption {
            type = lib.types.str;
            description = "Email address of the default admin (DEFAULT_ADMIN_EMAIL). The password is the `adminPassword` dependency.";
          };
          resetOnBoot = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Reset the default admin to these credentials on every start (`RESET_ADMIN_ON_BOOT`).";
          };
        };
      };
      description = "The default admin account.";
    };

    telemetry = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Send telemetry to Firezone (`TELEMETRY_ENABLED`).";
          };
        };
      };
      default = { };
      description = "Firezone telemetry.";
    };

    service = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.str;
            default = "ClusterIP";
            description = "Service `spec.type`.";
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Annotations on the Service.";
          };
        };
      };
      default = { };
      description = "The Service on ports 13000 (HTTP) and the WireGuard port (UDP).";
    };

    ingress = kix.options.ingress;

    # Neither the BeanVPN chart nor Firezone 0.7's docs set resources. An
    # idle instance holds under 100 MiB; startup (migrations) takes about
    # 15 CPU-seconds. The ConfigMap's ERL_FLAGS sizes the BEAM for two
    # CPUs; set `env.ERL_FLAGS` when changing limits.cpu.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "2";
        memory = "1Gi";
      };
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Firezone container";
    };
  };

  build = [
    (
      {
        self,
        config,
        database,
        applicationSecrets,
        adminPassword,
        wireguardKey,
        samlCertificate ? null,
        reloader ? null,
        scope,
        kix,
        ...
      }:
      let
        wg = config.wireguard;

        hasSaml = samlCertificate != null;

        # The image's bootstrap script writes a telemetry id and, without
        # SAML files, a self-signed SAML pair into /var/firezone, so that
        # directory is an emptyDir and the mounted secrets live beside it.
        secretsDir = "/var/firezone-secrets";
        samlDir = "/var/firezone-saml";

        appSecrets = kix.checkSecretKeys {
          inherit who;
          arg = "applicationSecrets";
          dep = applicationSecrets;
          keys = [
            "GUARDIAN_SECRET_KEY"
            "SECRET_KEY_BASE"
            "DATABASE_ENCRYPTION_KEY"
          ];
        };
        admin = kix.checkSecretKeys {
          inherit who;
          arg = "adminPassword";
          dep = adminPassword;
          keys = [ "password" ];
        };
        wgKey = kix.checkSecretKeys {
          inherit who;
          arg = "wireguardKey";
          dep = wireguardKey;
          keys = [ "private_key" ];
        };
        saml = kix.checkSecretKeys {
          inherit who;
          arg = "samlCertificate";
          dep = samlCertificate;
          keys = [
            "saml.crt"
            "saml.key"
          ];
        };
        dbCreds = database.out.credentials;

        # The salts are optional; Firezone treats an unset salt as empty.
        salts = builtins.filter (k: builtins.elem k (appSecrets.out.keys or [ ])) [
          "LIVE_VIEW_SIGNING_SALT"
          "COOKIE_SIGNING_SALT"
          "COOKIE_ENCRYPTION_SALT"
        ];

        secretEnv =
          appSecrets.out.mkEnv (
            lib.genAttrs (
              [
                "GUARDIAN_SECRET_KEY"
                "SECRET_KEY_BASE"
                "DATABASE_ENCRYPTION_KEY"
              ]
              ++ salts
            ) (k: k)
          )
          ++ admin.out.mkEnv { DEFAULT_ADMIN_PASSWORD = "password"; }
          ++ dbCreds.out.mkEnv {
            DATABASE_USER = "username";
            DATABASE_PASSWORD = "password";
          };

        # The container reads every secret once, at start, so a changed
        # secret must roll the pod. A Kix-built Secret has an identity hash
        # for the pod template; a `secret-ref` Secret has none, and the
        # reloader restarts the pod instead.
        secretDeps = builtins.filter (d: d != null) [
          appSecrets
          admin
          wgKey
          saml
          dbCreds
        ];
        kixBuilt = builtins.filter (d: d.out ? identityHash) secretDeps;
        untracked = builtins.filter (d: !(d.out ? identityHash)) secretDeps;
        checksums = builtins.listToAttrs (
          lib.imap0 (i: d: {
            name = "checksum/secret-${toString i}";
            value = d.out.identityHash;
          }) kixBuilt
        );
        withReload =
          args:
          if reloader == null || untracked == [ ] then args else reloader.out.withReloadOn untracked args;
      in
      {
        # --- ConfigMap: non-secret env vars ---
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-env";
          data = {
            EXTERNAL_URL = "https://${config.domain}";
            DATABASE_HOST = database.out.host;
            DATABASE_PORT = toString database.out.port;
            DATABASE_NAME = database.out.database;
            DEFAULT_ADMIN_EMAIL = config.admin.email;
            DEFAULT_CLIENT_ENDPOINT = "${config.domain}:${toString wg.port}";
            WIREGUARD_PORT = toString wg.port;
            WIREGUARD_IPV4_NETWORK = wg.ipv4Network;
            WIREGUARD_IPV4_ADDRESS = wg.ipv4Address;
            WIREGUARD_IPV6_NETWORK = wg.ipv6Network;
            WIREGUARD_IPV6_ADDRESS = wg.ipv6Address;
            TELEMETRY_ENABLED = if config.telemetry.enabled then "true" else "false";
            RESET_ADMIN_ON_BOOT = if config.admin.resetOnBoot then "true" else "false";
            WIREGUARD_PRIVATE_KEY_PATH = "${secretsDir}/private_key";
            # The BEAM starts one scheduler per node core. On a 32-core kind
            # node under a 1-CPU limit, startup ran past Postgrex's 15s
            # handshake timeout and never finished; two schedulers, matching
            # the default CPU limit, start in about 15 CPU-seconds.
            ERL_FLAGS = "+S 2:2";
            # The BEAM sizes its port table from the open-file limit, which
            # containerd can leave at 2^31; that table alone took 1.6 GiB.
            ERL_MAX_PORTS = "65536";
          }
          // lib.optionalAttrs hasSaml {
            SAML_CERTFILE_PATH = "${samlDir}/saml.crt";
            SAML_KEYFILE_PATH = "${samlDir}/saml.key";
          };
        };

        # --- Mounts: the WireGuard key and the optional SAML pair, as files ---
        wireguardMount = kix.mount.secret wgKey {
          name = "wireguard-key";
          mountPath = secretsDir;
          defaultMode = 256; # 0400
        };
        samlMount = kix.mount.secret saml {
          name = "saml-certificate";
          mountPath = samlDir;
          defaultMode = 256; # 0400
        };

        # --- Deployment ---
        deployment =
          {
            name = name;
            spec = {
              replicas = config.replicaCount;
              selector.matchLabels = scope.selectorLabels;
              template.metadata.annotations = checksums;
              template.spec = {
                # Kubernetes default: Firezone 0.7 documents no shutdown drain.
                terminationGracePeriodSeconds = 30;
                initContainers = [
                  {
                    name = "init-sysctl";
                    image = "busybox:1.36";
                    command = [
                      "sh"
                      "-c"
                      ''
                        sysctl -w net.ipv4.ip_forward=1
                        sysctl -w net.ipv6.conf.all.disable_ipv6=0
                        sysctl -w net.ipv6.conf.all.forwarding=1
                      ''
                    ];
                    securityContext = {
                      privileged = true;
                      readOnlyRootFilesystem = true;
                    };
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits = {
                        cpu = "100m";
                        memory = "32Mi";
                      };
                    };
                  }
                ];
                containers = [
                  {
                    name = "firezone";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    ports = [
                      (kix.port "wireguard" wg.port // { protocol = "UDP"; })
                      (kix.port "http" 13000)
                    ];
                    envFrom = [ { configMapRef.name = self.configMap.out.name; } ];
                    env = kix.mkEnv config.env secretEnv;
                    # Firezone 0.7 has no health endpoint; "/" redirects to
                    # the sign-in page once the web server is up.
                    livenessProbe = {
                      httpGet = {
                        path = "/";
                        port = "http";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 6;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/";
                        port = "http";
                      };
                      periodSeconds = 10;
                      timeoutSeconds = 5;
                      failureThreshold = 3;
                    };
                    startupProbe = {
                      httpGet = {
                        path = "/";
                        port = "http";
                      };
                      periodSeconds = 5;
                      failureThreshold = 60;
                    };
                    resources = config.resources;
                    securityContext = {
                      readOnlyRootFilesystem = true;
                      capabilities.add = [
                        "NET_ADMIN"
                        "SYS_MODULE"
                      ];
                    };
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            self.wireguardMount
            self.samlMount
            (kix.mount.emptyDir {
              name = "state";
              mountPath = "/var/firezone";
            })
            # The Elixir release writes RELEASE_TMP under /app/tmp.
            (kix.mount.emptyDir {
              name = "release-tmp";
              mountPath = "/app/tmp";
            })
            (kix.mount.emptyDir {
              name = "tmp";
              mountPath = "/tmp";
            })
          ]
          |> withReload
          |> scope.mkDeployment;

        # --- Service ---
        service =
          self.deployment
          |> kix.service.fromWorkload {
            name = name;
            type = config.service.type;
            annotations = config.service.annotations;
            outputs = {
              httpPort = "13000";
              wireguardPort = toString wg.port;
            };
          }
          |> scope.mkResource;

        # --- Entry point ---
        root = self.service;
      }
    )
    (kix.expose {
      service = "service";
      port = 13000;
    })
  ];
}
