# harbor: the Harbor OCI container registry.
#
# Components: core (API and auth), portal (web UI), registry (blob storage,
# with the registryctl sidecar), jobservice (replication, garbage
# collection, and other async jobs), and exporter (Harbor-wide metrics).
# The database and the cache are dependencies, not sub-components.
#
# Dependencies:
#   database (required)       a logical PostgreSQL database honouring the
#                             Postgres database contract
#                             (kix.contracts.postgresDatabase), such as
#                             stackgres-database or an RDS import. Harbor
#                             reads the role and password from
#                             out.credentials, and out.tls (whether the
#                             server speaks TLS); without it, set
#                             database.sslmode.
#   redis (required)          a Redis cache and job queue honouring
#                             kix.contracts.redis: a valkey, or a
#                             kix.mkImport for a server without TLS. Harbor
#                             asks Sentinel for the primary when the server
#                             publishes out.sentinel. Harbor uses fixed
#                             database indexes 0 to 2 and a fixed job-queue
#                             prefix, so give each Harbor instance its own
#                             server; for a second Harbor in one namespace,
#                             wire deps.redis = ref.<ns>.<valkey>.
#   storage (required)        a persistent volume for registry blobs.
#   harborSecrets (required)  a Secret declaring the keys in `secretKeys` in
#                             common.nix.
#   caBundle (optional)       a Secret declaring `ca.crt`: extra CA certificates
#                             (PEM) for a replication source, an OIDC provider,
#                             or a database behind a private CA.
#   ingressNginx / gateway / clusterIssuer (optional)  the route and its TLS,
#                             through kix.expose.
#   prometheus (optional)     the exporter, ServiceMonitors, and alerts.
#   reloader (optional)       restarts pods when a secret-ref Secret changes.
#   oidc (optional)           single sign-on, through an OpenID Connect
#                             client honouring kix.contracts.oidc; see below.
#
#   instances.harbor = {
#     harbor.package = packages.harbor;
#     harbor-secrets = {
#       package = packages.secret;
#       aliases = [ "harborSecrets" ];
#       config = {
#         source = ./harbor.sops.yaml;
#         keys = [ "adminPassword" "secretKey" "coreSecret" "jobserviceSecret"
#                  "csrfKey" "registryHttpSecret" "registryPassword" "tokenPrivateKey" ];
#       };
#     };
#     harbor-registry = {
#       package = packages.persistent-volume-claim;
#       aliases = [ "storage" ];
#       config.size = "100Gi";
#     };
#     harbor-valkey.package = packages.valkey;
#     valkey-password = {
#       package = packages.secret;
#       aliases = [ "valkeyPassword" ];
#       config = { source = ./valkey.sops.yaml; keys = [ "password" ]; };
#     };
#     harbor-db = {
#       package = packages.experimental.stackgres-database;
#       aliases = [ "database" ];
#       config.database = "registry";
#     };
#     harbor-db-password = {
#       package = packages.secret;
#       aliases = [ "password" ];
#       config = { source = ./harbor-db.sops.yaml; keys = [ "password" ]; };
#     };
#   };
#
# A SOPS secret lists its keys in `keys`, because Kix cannot read the
# encrypted file during evaluation. Generate the values with:
#   secretKey        openssl rand -hex 8    (exactly 16 characters)
#   csrfKey          openssl rand -hex 16   (exactly 32 characters)
#   tokenPrivateKey  openssl genrsa 4096
#   the others       openssl rand -hex 16
#
# The public URL (EXT_ENDPOINT) comes from the route kix.expose renders:
# `ingress.host`, else `<instance>.<cluster.domain>`, with https when the
# Ingress has a clusterIssuer or the Gateway listener terminates TLS. Set
# `externalURL` only when clients reach that host on another port or scheme.
#
# Rollouts: a pod restarts when a Kix-built Secret it reads changes
# (harborSecrets, caBundle, the database credentials, and the valkey
# password), through a `checksum/<name>` pod annotation. A Secret from
# `packages.secret-ref` carries no content hash. With a reloader dependency,
# the package names such Secrets in reloader's annotation on the
# Deployments that read them; without one, a change to them restarts no pod.
#
# Network policy: every component dials the others through
# `self.<service>.out.url`, so policy and deploy order derive from the
# manifests. Every Harbor pod may reach the world on TCP 443 for
# replication, proxy-cache, and OIDC. Other ports (LDAP on 389 or 636, a
# plain-HTTP replication source) need a CiliumNetworkPolicy added through
# the instance's partsOverlays. Through an Ingress, kix.expose opens core
# and portal to the controller; through a Gateway, no policy admits the
# Gateway's data plane yet.
#
# Single sign-on: with `oidc` wired (an oidc-client instance, or a
# kix.mkImport), core runs in `oidc_auth` mode against that client's issuer,
# with the client id and secret from its `out.credentials`. Register a
# confidential client with the redirect URI
# `<EXT_ENDPOINT>/c/oidc/callback`. Core applies the auth mode, the issuer,
# `oidc.scopes`, `oidc.groupsClaim`, and `oidc.adminGroup` from
# CONFIG_OVERWRITE_JSON on every start, with the client id and secret
# expanded into it by Kubernetes from the secret, so neither lands in a
# ConfigMap. The secret must hold no `"` or `\`, which would break that JSON;
# a secret Keycloak generates holds neither. Harbor then makes every
# setting read-only in its UI: set the others in `core.settings`. Harbor
# refuses to change the auth mode once users other than admin exist, and
# core exits at start when that change fails, so turn OIDC on before the
# first user signs in.
#
# Core discovers the provider at the issuer URL, the public URL, and
# requires the issuer the provider reports to match it, so it cannot use a
# Keycloak Service address. Derived policy has no edge for that request.
# The world:443 egress above admits it when the public URL resolves to a
# load balancer outside the cluster. When it resolves to an address the
# cluster's own data plane answers (a load balancer IP that Cilium or
# kube-proxy serves inside the cluster), the request reaches the ingress
# controller from a pod, which its policy does not admit.
#
# Core and jobservice dial each other, which would be a store-path cycle,
# so the core and jobservice Services use a literal selector rather than
# the Deployment's `out.selector`, and `root.requires` pulls in both
# Deployments.
#
# Not supported: the Trivy scanner, internal TLS, and object storage. The
# registry keeps blobs on the storage claim with the filesystem driver, so
# it runs one pod.
#
# Upgrades: core migrates the database when it starts, so a new version
# reads the data an older one wrote. From 2.15.2, 2.15.5 applies schema 181,
# which widens three columns to bigint. The registry's blobs on the storage
# claim need no migration. An older core does not start on a migrated
# database: it exits with "no migration found for version 181". Upstream
# supports no downgrade. To go back, scale core, jobservice, and the
# exporter to zero, restore the database from a backup taken before the
# upgrade, and deploy the older version.
#
# Escape hatches: core.env, jobservice.env, and exporter.env over the
# tunable environment; registry.settings and jobservice.settings over the
# two config.yml files; the instance's partsOverlays and each resource's
# `extra` for the rest.
#
# root = the route when exposed, otherwise the core Service.
#
# `out`: `version`, the Harbor version `core.image.tag` names.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    release
    tag
    who
    svc
    alerts
    ;

  harborImage =
    component: digest:
    kix.options.image {
      repository = "docker.io/goharbor/${component}";
      inherit tag digest;
      tagText = "config.core.image.tag";
      description = "Image of ${component}. Its tag follows core.image.tag.";
    };

  replicasOption =
    component: reason:
    lib.mkOption {
      type = lib.types.ints.positive;
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      defaultText = lib.literalMD "1 at availability `none`, otherwise 2";
      description = "Number of ${component} pods. ${reason}";
    };

  envOption =
    component: owned:
    kix.options.env
    // {
      description = ''
        Extra environment variables for ${component}, over the package's
        tunables (${owned}). A value is a string, a `fieldRef` source, or a
        `secretKeyRef` source naming a Secret managed outside Kix with
        `kix.untrackedRef`; null removes a tunable. Addresses and
        credentials the package derives from its dependencies cannot be
        set here.
      '';
    };
in
{
  meta = {
    version = release;
    description = "Harbor: OCI container registry";
    owner = "platform";
    # Upstream's Helm chart README states Kubernetes 1.20 or later and
    # names no newest version. Its compatibility matrix lists only the
    # versions upstream tests, so it sets no upper bound.
    k8s = {
      minVersion = "1.20";
      reason = "[K5312] Harbor ${release} supports Kubernetes 1.20 or later";
    };
    # Replication, proxy-cache, and OIDC reach external registries and
    # identity providers over HTTPS. Intents apply to every workload in the
    # package.
    network.intents.upstream-https.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;
  deps.redis = {
    assertions = dep: kix.contracts.redis.assertions who dep;
    renamedFrom = kix.contracts.redis.helpers.renamedFrom;
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.oidc.adminGroup == null || config.oidc.groupsClaim != null;
        message = "oidc.adminGroup is ${builtins.toJSON config.oidc.adminGroup}, but oidc.groupsClaim is null, so Harbor reads no groups to match it against. Set oidc.groupsClaim to the claim that lists the user's groups, such as \"groups\".";
      }
    ];

  options = {
    oidc =
      kix.contracts.oidc.options {
        scopes = [
          "openid"
          "profile"
          "email"
          "offline_access"
        ];
      }
      // {
        groupsClaim = lib.mkOption {
          type = lib.types.nullOr lib.types.nonEmptyStr;
          default = null;
          example = "groups";
          description = "The ID token claim that lists the user's groups (`oidc_groups_claim`). Harbor creates a group for each and maps project membership to it. Keycloak adds such a claim through a \"Group Membership\" mapper on the client.";
        };
        adminGroup = lib.mkOption {
          type = lib.types.nullOr lib.types.nonEmptyStr;
          default = null;
          example = "harbor-admins";
          description = "Members of this group, read from `groupsClaim`, are Harbor system administrators (`oidc_admin_group`). Requires `groupsClaim`.";
        };
      };

    externalURL = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "https?://[^/]+");
      default = null;
      example = "https://harbor.example.com:8443";
      description = ''
        URL clients use to reach Harbor (EXT_ENDPOINT), when it differs from
        the route Kix renders. The host must be one that route serves
        (`ingress.host`, else `<instance>.<cluster.domain>`): registry
        clients follow the token realm to this URL, so a host the route does
        not serve breaks `docker login`. Set it only to add a port (a
        port-forward) or a scheme that an external load balancer
        terminates. No path: Harbor does not serve under a sub-path. Null
        derives it from the route.
      '';
    };

    ingress = kix.options.ingress;

    metrics = kix.options.monitor;

    database.sslmode = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "disable"
          "allow"
          "prefer"
          "require"
          "verify-ca"
          "verify-full"
        ]
      );
      default = null;
      description = ''
        libpq sslmode for core, jobservice, and the exporter. Null derives
        it from the database dependency's `out.tls`: "require" when the
        server speaks TLS, "disable" when it does not.
      '';
    };

    core = {
      image = kix.options.image {
        repository = "docker.io/goharbor/harbor-core";
        inherit tag;
        digest = "sha256:f7c0ad9b8bae40d4a6460e80be88b6c7d624eebdfbb5690b5b7ae13b4c1bd862";
        description = "Image of Harbor core. The other Harbor images follow its tag.";
      };
      replicas = replicasOption "core" "Core is a stateless API; its state lives in the database and valkey.";
      resources = kix.options.resources {
        requests = {
          cpu = "20m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      };
      env = envOption "core" "LOG_LEVEL, PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE, REPLICATION_ADAPTER_WHITELIST, POSTGRESQL_MAX_IDLE_CONNS, and POSTGRESQL_MAX_OPEN_CONNS";
      settings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.bool
            lib.types.int
            lib.types.str
          ]
        );
        default = { };
        example = {
          oidc_auto_onboard = true;
          oidc_user_claim = "preferred_username";
          project_creation_restriction = "adminonly";
        };
        description = ''
          Harbor configuration items (the keys of `GET /api/v2.0/configurations`),
          which core applies from CONFIG_OVERWRITE_JSON on every start. A
          non-empty value, or an `oidc` dependency, makes every setting
          read-only in Harbor's UI. With `oidc` wired the package sets `auth_mode`,
          `oidc_endpoint`, `oidc_client_id`, `oidc_client_secret`,
          `oidc_scope`, `oidc_groups_claim`, and `oidc_admin_group`, and
          refuses them here; it defaults `oidc_name` to "OpenID Connect".
          `oidc_client_secret` and `ldap_search_password` are always
          refused, because the value would land in the pod spec. Values
          reach Harbor as written: the package escapes `$` against
          Kubernetes' `$(VAR)` expansion.
        '';
      };
    };

    portal = {
      image = harborImage "harbor-portal" "sha256:2c05137a69a8f1cd51ce238b81f70d774396ff3a92494351857ced142d03253d";
      replicas = replicasOption "portal" "The portal serves a static web UI.";
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
    };

    registry = {
      image = harborImage "registry-photon" "sha256:6f9670a13d7f0ba2f896c571543343c1fcd9a36f585e30fe0f8c4edc9a0f8aa9";
      resources = kix.options.resources {
        requests = {
          cpu = "20m";
          memory = "64Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = {
          storage.maintenance.uploadpurging.age = "72h";
          log.level = "debug";
        };
        description = ''
          Distribution `config.yml` keys, merged over the package's own. A
          null removes a key the package sets. `storage` accepts only
          `cache`, `maintenance`, `delete`, `redirect`, and `tag`: blobs stay
          on the storage claim with the filesystem driver. The package locks
          `storage.filesystem`, `redis.addr`, `redis.db`,
          `redis.sentinelMasterSet`, `redis.password`, `http.addr`,
          `http.debug`, and `auth`; setting one fails evaluation.
        '';
      };
    };

    registryctl = {
      image = harborImage "harbor-registryctl" "sha256:e3c64071cf72f47566f27a16d8a57c6a71ec710e72ba9190168d24103eb57925";
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
    };

    jobservice = {
      image = harborImage "harbor-jobservice" "sha256:aafa49237fef5ce8be2990caf7dcd4c9ff8d921d77c129bd36e4a5c510868a7c";
      replicas = replicasOption "jobservice" "Job logs live in the database, so any pod can serve any job's log.";
      resources = kix.options.resources {
        requests = {
          cpu = "20m";
          memory = "128Mi";
        };
        limits = {
          cpu = "2";
          memory = "1Gi";
        };
      };
      env = envOption "jobservice" "LOG_LEVEL, REGISTRY_HTTP_CLIENT_TIMEOUT in minutes, JOBSERVICE_WEBHOOK_JOB_MAX_RETRY, and JOBSERVICE_WEBHOOK_JOB_HTTP_CLIENT_TIMEOUT in seconds";
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = {
          worker_pool.workers = 20;
          reaper.max_update_hours = 48;
        };
        description = ''
          Jobservice `config.yml` keys, merged over the package's own, such
          as `worker_pool.workers` (10), `reaper`, and `loggers`. A null
          removes a key the package sets. The package locks `protocol`,
          `port`, `worker_pool.backend`, `worker_pool.redis_pool.namespace`,
          `worker_pool.redis_pool.redis_url`, `job_loggers`, and `metric`;
          setting one fails evaluation.
        '';
      };
    };

    exporter = {
      image = harborImage "harbor-exporter" "sha256:d1fa474567b6b1efb5325570f523de457efec4d2ba871691c2982835f76b87ac";
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
      env = envOption "the exporter" "LOG_LEVEL, HARBOR_DATABASE_MAX_IDLE_CONNS, HARBOR_DATABASE_MAX_OPEN_CONNS, HARBOR_EXPORTER_CACHE_TIME, and HARBOR_EXPORTER_CACHE_CLEAN_INTERVAL";
    };

    htpasswd.image = kix.options.image {
      repository = "docker.io/library/httpd";
      tag = "2.4.68-alpine";
      digest = "sha256:4e585da9d0125dec36d4500a9f5c5df7b2c0a01f67cb47865a91a4b05bdbec1b";
      description = "Image of the registry's init container, which writes the htpasswd line for registryPassword with the image's `htpasswd`.";
    };
  };

  config =
    { config, ... }:
    {
      portal.image.tag = lib.mkDefault config.core.image.tag;
      registry.image.tag = lib.mkDefault config.core.image.tag;
      registryctl.image.tag = lib.mkDefault config.core.image.tag;
      jobservice.image.tag = lib.mkDefault config.core.image.tag;
      exporter.image.tag = lib.mkDefault config.core.image.tag;
    };

  build = [
    ./core.nix
    ./registry.nix
    ./jobservice.nix

    (
      { self, config, ... }:
      {
        # Reachable through the route: the core and portal Services.
        # Neither the core nor the jobservice Service carries a workload
        # edge (see core.nix and jobservice.nix), so both Deployments are
        # listed here; core's ConfigMap reaches every other component. No
        # other part refers to the exporter Service, so it is listed too.
        root = {
          resource = if self.route != null then self.route else self.coreService;
          requires = builtins.filter (r: r != null) [
            self.coreDeployment
            self.jobserviceDeployment
            self.exporterService
          ];
          out.version = kix.image.version config.core.image;
        };
      }
    )

    # API paths route to core, everything else to the portal. A layer
    # upload can outlast Envoy Gateway's 15s default route timeout, and
    # Gateway API reads "0s" as no timeout.
    (kix.expose {
      paths = [
        {
          path = "/api/";
          service = "coreService";
        }
        {
          path = "/service/";
          service = "coreService";
        }
        {
          path = "/v2/";
          service = "coreService";
        }
        {
          path = "/c/";
          service = "coreService";
        }
        {
          path = "/";
          service = "portalService";
        }
      ];
      timeouts.request = "0s";
      defaultAnnotations."nginx.ingress.kubernetes.io/proxy-body-size" = "0";
    })

    # One ServiceMonitor per metrics Service. The core entry also carries
    # the alert rules for every component.
    (kix.monitor {
      service = "coreService";
      port = "http-metrics";
      name = svc.core;
      monitorPart = "coreMonitor";
      rulesPart = "coreAlerts";
      inherit alerts;
    })
    (kix.monitor {
      service = "registryService";
      port = "http-metrics";
      name = svc.registry;
      monitorPart = "registryMonitor";
      rulesPart = "registryAlerts";
    })
    (kix.monitor {
      service = "jobserviceService";
      port = "http-metrics";
      name = svc.jobservice;
      monitorPart = "jobserviceMonitor";
      rulesPart = "jobserviceAlerts";
    })
    (kix.monitor {
      service = "exporterService";
      port = "http-metrics";
      name = svc.exporter;
      monitorPart = "exporterMonitor";
      rulesPart = "exporterAlerts";
    })
  ];
}
