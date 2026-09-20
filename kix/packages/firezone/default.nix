# Firezone — self-hosted WireGuard VPN server with web UI.
#
# Based on BeanVPN/firezone-helm-chart but with proper secret management
# (no hardcoded keys — all secrets must be provided via config).
#
# Dependencies:
#   postgres            — required, database backend
#
# Exposure: uses kix.expose (port 13000) for optional ingress/TLS.
#
# Resources: Secret (env), Secret (files), ConfigMap (env), Deployment, Service.
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
in
{
  meta = {
    version = "0.7.26";
    description = "Firezone — self-hosted WireGuard VPN";
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

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "firezone/firezone";
        tag = "0.7.26";
        pullPolicy = "IfNotPresent";
      };
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
      type = lib.types.anything;
      default = {
        port = 51820;
        privateKey = null;
        ipv4Network = "100.64.0.0/10";
        ipv4Address = "100.64.0.1";
        ipv6Network = "fd00::/106";
        ipv6Address = "fd00::1";
      };
      description = "WireGuard configuration. privateKey must be set.";
    };

    admin = lib.mkOption {
      type = lib.types.anything;
      default = {
        email = null;
        password = null;
        resetOnBoot = true;
      };
      description = "Default admin credentials. Both email and password must be set.";
    };

    secrets = lib.mkOption {
      type = lib.types.anything;
      default = {
        guardianSecretKey = null;
        secretKeyBase = null;
        liveViewSigningSalt = null;
        cookieSigningSalt = null;
        cookieEncryptionSalt = null;
        databaseEncryptionKey = null;
      };
      description = "Application secrets. All must be set for production use.";
    };

    database = lib.mkOption {
      type = lib.types.anything;
      default = {
        name = "firezone";
        user = "firezone";
        passwordSecretRef = null;
      };
      description = "Database configuration. passwordSecretRef = { name, key } for existing secret.";
    };

    saml = lib.mkOption {
      type = lib.types.anything;
      default = {
        cert = null;
        key = null;
      };
      description = "SAML certificate and key (PEM strings). Null to disable.";
    };

    telemetry = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
    };

    service = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "ClusterIP";
        annotations = { };
      };
    };

    ingress = kix.options.ingress;

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Firezone container";
    };
  };

  assertions =
    {
      config,
      self,
      deps,
    }:
    [
      {
        assertion = config.wireguard.privateKey != null;
        message = "firezone: wireguard.privateKey must be set";
      }
      {
        assertion = config.admin.email != null;
        message = "firezone: admin.email must be set";
      }
      {
        assertion = config.admin.password != null;
        message = "firezone: admin.password must be set";
      }
      {
        assertion = config.secrets.guardianSecretKey != null;
        message = "firezone: secrets.guardianSecretKey must be set";
      }
      {
        assertion = config.secrets.secretKeyBase != null;
        message = "firezone: secrets.secretKeyBase must be set";
      }
      {
        assertion = config.secrets.databaseEncryptionKey != null;
        message = "firezone: secrets.databaseEncryptionKey must be set";
      }
    ];

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        postgres,
        scope,
        kix,
        ...
      }:
      let
        wg = config.wireguard;

        hasSaml = config.saml.cert != null && config.saml.key != null;

        dbPasswordEnv =
          if config.database.passwordSecretRef != null then
            [
              {
                name = "DATABASE_PASSWORD";
                valueFrom.secretKeyRef = {
                  name = config.database.passwordSecretRef.name;
                  key = config.database.passwordSecretRef.key;
                };
              }
            ]
          else
            [ ];
      in
      {
        # --- ConfigMap: non-secret env vars ---
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-env";
          data = {
            EXTERNAL_URL = "https://${config.domain}";
            DATABASE_HOST = postgres.out.fqdn;
            DATABASE_PORT = postgres.out.port;
            DATABASE_NAME = config.database.name;
            DATABASE_USER = config.database.user;
            DEFAULT_CLIENT_ENDPOINT = "${config.domain}:${toString wg.port}";
            WIREGUARD_PORT = toString wg.port;
            WIREGUARD_IPV4_NETWORK = wg.ipv4Network;
            WIREGUARD_IPV4_ADDRESS = wg.ipv4Address;
            WIREGUARD_IPV6_NETWORK = wg.ipv6Network;
            WIREGUARD_IPV6_ADDRESS = wg.ipv6Address;
            TELEMETRY_ENABLED = if config.telemetry.enabled then "true" else "false";
            RESET_ADMIN_ON_BOOT = if config.admin.resetOnBoot then "true" else "false";
          };
        };

        # --- Secret: sensitive env vars ---
        envSecret = scope.mkSecret {
          name = "${name}-env";
          stringData = {
            DEFAULT_ADMIN_EMAIL = config.admin.email;
            DEFAULT_ADMIN_PASSWORD = config.admin.password;
            GUARDIAN_SECRET_KEY = config.secrets.guardianSecretKey;
            SECRET_KEY_BASE = config.secrets.secretKeyBase;
            LIVE_VIEW_SIGNING_SALT = config.secrets.liveViewSigningSalt or "";
            COOKIE_SIGNING_SALT = config.secrets.cookieSigningSalt or "";
            COOKIE_ENCRYPTION_SALT = config.secrets.cookieEncryptionSalt or "";
            DATABASE_ENCRYPTION_KEY = config.secrets.databaseEncryptionKey;
          };
        };

        # --- Secret: file-based secrets (WireGuard key, optional SAML) ---
        filesSecret = scope.mkSecret {
          name = "${name}-files";
          stringData = {
            private_key = config.wireguard.privateKey;
          }
          // lib.optionalAttrs hasSaml {
            "saml.crt" = config.saml.cert;
            "saml.key" = config.saml.key;
          };
        };

        # --- Mounts ---
        filesMount = kix.mount.secret self.filesSecret {
          mountPath = "/var/firezone";
          defaultMode = 256; # 0400
        };

        # --- Deployment ---
        deployment =
          {
            name = name;
            spec = {
              replicas = config.replicaCount;
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
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
                    securityContext.privileged = true;
                  }
                ];
                containers = [
                  {
                    name = "firezone";
                    image = "${config.image.repository}:${config.image.tag}";
                    imagePullPolicy = config.image.pullPolicy;
                    ports = [
                      (kix.port "wireguard" wg.port // { protocol = "UDP"; })
                      (kix.port "http" 13000)
                    ];
                    envFrom = [
                      { configMapRef.name = self.configMap.out.name; }
                      self.envSecret.out.envFrom
                    ];
                    env = kix.mkEnv config.env dbPasswordEnv;
                    securityContext.capabilities.add = [
                      "NET_ADMIN"
                      "SYS_MODULE"
                    ];
                  }
                ];
              };
            };
          }
          |> kix.withMounts [ self.filesMount ]
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
