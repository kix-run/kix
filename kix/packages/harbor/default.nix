# Harbor container registry.
#
# Multi-component OCI registry: core (API and auth), portal (web UI),
# registry (blob storage, with the registryctl sidecar), jobservice
# (replication, garbage collection, and other async jobs), and exporter
# (Harbor-wide metrics). The database and the cache are dependencies, not
# sub-components (BEST-PRACTICES §12.5).
#
# Dependencies:
#   database (required)       a logical PostgreSQL database: stackgres-database,
#                             or anything publishing out.{host,port,database,
#                             username,credentials} with a `password` key on the
#                             credentials, and out.tls (whether the server
#                             speaks TLS). Without out.tls, set database.sslmode.
#   valkey (required)         Redis-compatible cache and job queue
#                             (out.{fqdn,port,authSecret,authPasswordKey}),
#                             reached through Sentinel when the instance
#                             publishes out.{sentinelPort,primarySet}.
#   storage (required)        a persistent volume for registry blobs.
#   harborSecrets (required)  a Secret declaring the keys in `secretKeys` below.
#   caBundle (optional)       a Secret declaring `ca.crt`: extra CA certificates
#                             (PEM) for a replication source, an OIDC provider,
#                             or a database behind a private CA.
#   ingressNginx / gateway / clusterIssuer (optional)  the route and its TLS,
#                             through kix.expose.
#   prometheus (optional)     the exporter, ServiceMonitors, and alerts.
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
#       package = packages.stackgres-database;
#       aliases = [ "database" ];
#       config = { database = "registry"; passwordSource = ./harbor-db.sops.yaml; passwordHash = "..."; };
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
# Rollouts: a pod restarts when a Kix-built Secret it reads changes. A
# Secret from `packages.secret-ref` carries no content hash, so use
# reloader's `withReloadOn` for it.
#
# Network policy: every component dials the others through
# `self.<service>.out.fqdn`, so policy and deploy order derive from the
# manifests. Every Harbor pod may reach the world on TCP 443 for
# replication, proxy-cache, and OIDC. Other ports (LDAP on 389 or 636, a
# plain-HTTP replication source) need a CiliumNetworkPolicy added through
# the instance's partsOverlays. Through an Ingress, kix.expose opens core
# and portal to the controller; through a Gateway, no policy admits the
# Gateway's data plane yet (ROADMAP, "kix.expose with paths renders an
# HTTPRoute").
#
# Core and jobservice dial each other, which would be a store-path cycle,
# so the core and jobservice Services use a literal selector rather than
# the Deployment's `out.selector` (BEST-PRACTICES §7.3), and `root.requires`
# pulls in both Deployments.
#
# Not supported: the Trivy scanner, internal TLS, and object storage. The
# registry keeps blobs on the storage claim with the filesystem driver, so
# it runs one pod.
#
# Escape hatches: core.env, jobservice.env, and exporter.env over the
# tunable environment; registry.settings and jobservice.settings over the
# two config.yml files; the instance's partsOverlays and each resource's
# `extra` for the rest.
#
# root = the route when exposed, otherwise the core Service.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  who = "harbor ${scope.namespaceName}/${name}";
  release = "2.15.2";
  tag = "v${release}";

  # Every component serves /metrics on this port when metrics are on.
  metricsPort = 8001;
  registryUser = "harbor_registry_user";

  # Service names, shared by the Service builders and the alert selectors.
  svc = {
    core = "${name}-core";
    portal = "${name}-portal";
    registry = "${name}-registry";
    jobservice = "${name}-jobservice";
    exporter = "${name}-exporter";
  };

  secretKeys = [
    "adminPassword" # initial admin login (HARBOR_ADMIN_PASSWORD)
    "secretKey" # 16 characters, encrypts credentials Harbor stores in the database
    "coreSecret" # CORE_SECRET: core, jobservice, and registryctl authenticate each other
    "jobserviceSecret" # JOBSERVICE_SECRET
    "csrfKey" # CSRF_KEY, 32 characters
    "registryHttpSecret" # REGISTRY_HTTP_SECRET, signs the registry's upload state
    "registryPassword" # core and jobservice log in to the registry with it
    "tokenPrivateKey" # RSA private key (PEM) that signs registry bearer tokens
  ];

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

  sel = s: ''namespace="${scope.namespaceName}",service="${s}"'';

  alerts = {
    HarborHealthCheckFailed = {
      expr = "harbor_health{${sel svc.exporter}} == 0";
      "for" = "5m";
      severity = "critical";
      summary = "Harbor health check failed";
      description = "Harbor ${scope.namespaceName}/${name} reports an unhealthy component.";
    };
    HarborCoreHighInflightRequests = {
      expr = "harbor_core_http_inflight_requests{${sel svc.core}} > 100";
      "for" = "10m";
      severity = "warning";
      summary = "High number of inflight requests in Harbor core";
      description = "Harbor core pod {{ $labels.pod }} has more than 100 inflight requests.";
    };
    HarborCoreHighRequestDuration = {
      expr = "(sum by (method, pod) (rate(harbor_core_http_request_duration_seconds_sum{${sel svc.core}}[1m])) / sum by (method, pod) (rate(harbor_core_http_request_duration_seconds_count{${sel svc.core}}[1m]))) > 1";
      "for" = "10m";
      severity = "warning";
      summary = "High request duration in Harbor core";
      description = "Harbor core pod {{ $labels.pod }} has an average {{ $labels.method }} request duration above 1 second.";
    };
    HarborCoreHttp5xxRequestErrors = {
      expr = ''sum(rate(harbor_core_http_request_total{code=~"5..",${sel svc.core}}[5m])) / sum(rate(harbor_core_http_request_total{${sel svc.core}}[5m])) > 0.1'';
      "for" = "10m";
      severity = "critical";
      summary = "High rate of HTTP 5xx errors in Harbor core";
      description = "More than 10% of Harbor ${scope.namespaceName}/${name} core requests return HTTP 5xx.";
    };
    HarborProjectQuotaUsageHigh = {
      expr = "(harbor_project_quota_usage_byte{${sel svc.exporter}} / harbor_project_quota_byte{${sel svc.exporter}}) > 0.8";
      "for" = "10m";
      severity = "warning";
      summary = "High quota usage in Harbor project";
      description = "Quota usage in Harbor project {{ $labels.project_name }} is above 80%.";
    };
    HarborTaskQueueSizeHigh = {
      expr = "harbor_task_queue_size{${sel svc.exporter}} > 20";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue size in Harbor";
      description = "Harbor ${scope.namespaceName}/${name} has more than 20 {{ $labels.type }} tasks queued.";
    };
    HarborTaskQueueLatencyHigh = {
      expr = "harbor_task_queue_latency{${sel svc.exporter}} > 60";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue latency in Harbor";
      description = "Harbor ${scope.namespaceName}/${name} {{ $labels.type }} tasks wait more than 60 seconds in the queue.";
    };
    HarborTaskConcurrencyHigh = {
      expr = "harbor_task_concurrency{${sel svc.exporter}} > 10";
      "for" = "10m";
      severity = "warning";
      summary = "High task concurrency in Harbor";
      description = "Harbor ${scope.namespaceName}/${name} runs more than 10 {{ $labels.type }} tasks at once.";
    };
    HarborInstanceDown = {
      expr = ''up{namespace="${scope.namespaceName}",service=~"${
        lib.concatStringsSep "|" [
          svc.core
          svc.registry
          svc.jobservice
          svc.exporter
        ]
      }"} == 0'';
      "for" = "5m";
      severity = "critical";
      summary = "Harbor component is down";
      description = "Harbor target {{ $labels.service }} ({{ $labels.pod }}) is down.";
    };
  };
in
{
  meta = {
    version = release;
    description = "Harbor: OCI container registry";
    owner = "platform";
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

  options = {
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
        digest = "sha256:d7b780d23721a000f0fb8e181add6675eafa336de5d033b77fd7da0c171ff7f7";
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
    };

    portal = {
      image = harborImage "harbor-portal" "sha256:b811b67f7a7f6f1614e4bdf7478b207d13e8aa3f815ff6ad84f216a5098d213d";
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
      image = harborImage "registry-photon" "sha256:c4ebef61ceb50a3d8bc21d149bc280422db20a1e69df317b64b74098c3615855";
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
      image = harborImage "harbor-registryctl" "sha256:223d5cb49d5dbf0ba4ae022e7dd9775fa459904112dc12084d3aaa36c1408362";
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
      image = harborImage "harbor-jobservice" "sha256:f71a4452a095bcd2a8f0683648a3ae28415432df87ccfb00ec7625f3e340a598";
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
      image = harborImage "harbor-exporter" "sha256:e1b0a248f61aad5084c5d1612d5f1da89f99c23ce743eaf8cba913d6d00c0547";
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
    (
      {
        self,
        config,
        clusterConfig,
        scope,
        kix,
        database,
        valkey,
        storage,
        harborSecrets,
        caBundle ? null,
        prometheus ? null,
        ...
      }:
      let
        metricsEnabled = config.metrics.enabled && prometheus != null;

        # Every read of a secret dependency goes through these bindings, so
        # a missing key fails here with the secret's name, before any
        # `keyRef` throws.
        secrets = kix.checkSecretKeys {
          inherit who;
          arg = "harborSecrets";
          dep = harborSecrets;
          keys = secretKeys;
        };
        ca = kix.checkSecretKeys {
          inherit who;
          arg = "caBundle";
          dep = caBundle;
          keys = [ "ca.crt" ];
        };
        dbCredentials = kix.checkSecretKeys {
          inherit who;
          arg = "database";
          dep = database.out.credentials;
          keys = [ "password" ];
        };

        # A pod template annotation that changes with a Secret's content,
        # so the pods roll when it changes. A secret-ref has no content
        # hash and gets none.
        checksumOf =
          key: s: lib.optionalAttrs (s.out ? identityHash) { "checksum/${key}" = s.out.identityHash; };

        # --- Public URL ---
        exposure = self.exposure;
        hostKnown = config.ingress.host != null || (clusterConfig.cluster.domain or null) != null;
        urlProblem =
          if !hostKnown then
            "Set ingress.host or cluster.domain."
          else if exposure.via == null then
            "Wire ingressNginx or a gateway so kix.expose routes to Harbor."
          else
            "Kix cannot tell whether the gateway's listener terminates TLS.";
        externalURL =
          if config.externalURL != null then
            config.externalURL
          else if exposure.url != null then
            exposure.url
          else
            throw "${who}: Harbor needs the URL clients reach it on (EXT_ENDPOINT), and Kix cannot derive one. ${urlProblem} Or set externalURL.";

        # --- Database ---
        dbTls = database.out.tls or null;
        sslmode =
          if config.database.sslmode != null then
            config.database.sslmode
          else if dbTls == true then
            "require"
          else if dbTls == false then
            "disable"
          else
            throw "${who}: the database dependency does not say whether it serves TLS (it publishes no out.tls). Set database.sslmode to \"require\" for a server with TLS, or \"disable\" for one without.";
        dbPasswordEnv = var: dbCredentials.out.mkEnv { ${var} = "password"; };

        # --- Internal addresses ---
        # `out.fqdn` carries the endpoint fact: the consuming pod gets the
        # netpol egress and waits for the Service.
        coreUrl = "http://${self.coreService.out.fqdn}:${self.coreService.out.port}";
        tokenServiceUrl = "${coreUrl}/service/token";
        portalUrl = "http://${self.portalService.out.fqdn}:${self.portalService.out.port}";
        registryUrl = "http://${self.registryService.out.fqdn}:5000";
        registryCtlUrl = "http://${self.registryService.out.fqdn}:8080";
        jobserviceUrl = "http://${self.jobserviceService.out.fqdn}:${self.jobserviceService.out.port}";

        # Valkey. The password arrives as REDIS_PASSWORD from valkey's own
        # Secret and Kubernetes splices it into each URL through $(VAR)
        # expansion, so no ConfigMap carries it.
        redisAuth = valkey.out ? authSecret;
        # With Sentinel on, the valkey Service also routes to read-only
        # replicas, so Harbor asks Sentinel for the primary: the
        # `redis+sentinel://<sentinels>/<primary set>/<db>` URL and the
        # registry's `sentinelMasterSet`, as harbor-helm writes them for an
        # external Sentinel.
        redisSentinel = valkey.out ? sentinelPort;
        redisAddr =
          if redisSentinel then
            "${valkey.out.fqdn}:${valkey.out.sentinelPort}"
          else
            "${valkey.out.fqdn}:${valkey.out.port}";
        redisUrl =
          db:
          "${
            if redisSentinel then "redis+sentinel" else "redis"
          }://${lib.optionalString redisAuth ":$(REDIS_PASSWORD)@"}${redisAddr}${lib.optionalString redisSentinel "/${valkey.out.primarySet}"}/${toString db}";
        redisPasswordRef =
          var: valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey // { name = var; };
        redisPasswordEnv = lib.optional redisAuth (redisPasswordRef "REDIS_PASSWORD");
        valkeyChecksum = lib.optionalAttrs redisAuth (checksumOf "valkey-password" valkey.out.authSecret);

        # --- Environment ---
        # Go's crypto/x509 on Linux reads the first bundle file it finds
        # (/etc/pki/tls/certs/ca-bundle.crt on Photon) plus every file in
        # each SSL_CERT_DIR directory. The first two entries are Go's
        # defaults; a directory that does not exist is skipped.
        caTrust.SSL_CERT_DIR = "/etc/ssl/certs:/etc/pki/tls/certs:/harbor_cust_cert";

        # A component's env list: the Secret references first (Kubernetes
        # expands $(VAR) only from entries earlier in the list), then the
        # tunables with the instance's `env` over them, then the variables
        # the package owns. `facts` are the keys of the component's
        # ConfigMap, which reaches the pod through envFrom; an `env` entry
        # of the same name would win over it, so `env` may not set one.
        componentEnv =
          {
            option,
            secretEnv,
            facts ? [ ],
            sslmodeVar ? null,
            vars ? { },
            tunables ? { },
            env ? { },
          }:
          secretEnv
          ++ kix.mkEnvVars (
            kix.mergeEnv {
              inherit who;
              defaults = tunables;
              owned = [
                {
                  names = lib.remove sslmodeVar facts;
                  from = "a ConfigMap the package derives from its dependencies";
                  fix = "Remove it from ${option}.";
                }
                {
                  names = map (e: e.name) secretEnv;
                  from = "a dependency's Secret";
                  fix = "Remove it from ${option}; wire another Secret through deps.";
                }
                {
                  inherit vars;
                  from = "the package's dependencies";
                  fix = "Remove it from ${option}.";
                }
                {
                  vars = caTrust;
                  from = "the package, which adds the caBundle dependency to Go's certificate search path";
                  fix = "Remove it from ${option}; wire a caBundle dependency to trust another CA.";
                }
              ]
              ++ lib.optional (sslmodeVar != null) {
                names = [ sslmodeVar ];
                from = "database.sslmode";
                fix = "Set database.sslmode instead.";
              };
            } env
          );

        # --- Shared pod bits ---
        componentSelector =
          component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };
        coreSelector = componentSelector "core";
        jobserviceSelector = componentSelector "jobservice";
        componentLabels = component: {
          "app.kubernetes.io/component" = component;
        };

        containerSecurityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          privileged = false;
          # Each container mounts an emptyDir at every path it writes: /tmp,
          # plus /etc/core/ca and /etc/core/token for core. The images'
          # entrypoints run install_cert.sh first, which appends certificates
          # to /etc/pki/tls/certs/ca-bundle.crt in the image. Each container's
          # `command` and `args` are the exec line of its v2.15.2 entrypoint
          # script instead, and SSL_CERT_DIR has the Go binaries read
          # /harbor_cust_cert directly.
          readOnlyRootFilesystem = true;
          runAsNonRoot = true;
          seccompProfile.type = "RuntimeDefault";
        };
        caBundleMount =
          if ca == null then
            null
          else
            kix.mount.secret ca {
              name = "ca-bundle-certs";
              mountPath = "/harbor_cust_cert/custom-ca.crt";
              subPath = "ca.crt";
            };

        tmpMount =
          name:
          kix.mount.emptyDir {
            inherit name;
            mountPath = "/tmp";
          };

        harborPodDefaults = {
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
          };
          automountServiceAccountToken = false;
          terminationGracePeriodSeconds = 120;
        };

        # Per-component probes: base holds shared thresholds, each component
        # overrides httpGet.
        probeBase = {
          httpGet = {
            scheme = "HTTP";
            port = 8080;
          };
          periodSeconds = 10;
          failureThreshold = 3;
          timeoutSeconds = 1;
        };
        coreProbe = lib.recursiveUpdate probeBase {
          httpGet.path = "/api/v2.0/ping";
          failureThreshold = 2;
        };
        portalProbe = lib.recursiveUpdate probeBase { httpGet.path = "/"; };
        registryProbe = lib.recursiveUpdate probeBase {
          httpGet = {
            path = "/";
            port = 5000;
          };
        };
        registryCtlProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/health"; };
        jobserviceProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v1/stats"; };
        exporterProbe = lib.recursiveUpdate probeBase {
          httpGet = {
            path = "/";
            port = metricsPort;
          };
        };

        metricsContainerPort = lib.optional metricsEnabled (kix.port "metrics" metricsPort);
        # Numeric targetPorts throughout: the netpol layer copies them
        # into consumers' egress rules, and cilium drops a named one.
        metricsServicePort = lib.optional metricsEnabled {
          name = "http-metrics";
          port = metricsPort;
          targetPort = metricsPort;
          protocol = "TCP";
        };

        # --- ConfigMap data: the facts each component reads through envFrom ---
        coreConfigData = {
          EXT_ENDPOINT = externalURL;
          CONFIG_PATH = "/etc/core/app.conf";
          CORE_URL = coreUrl;
          CORE_LOCAL_URL = "http://127.0.0.1:8080";
          JOBSERVICE_URL = jobserviceUrl;
          REGISTRY_URL = registryUrl;
          REGISTRY_CONTROLLER_URL = registryCtlUrl;
          TOKEN_SERVICE_URL = tokenServiceUrl;
          PORTAL_URL = portalUrl;
          REGISTRY_STORAGE_PROVIDER_NAME = "filesystem";
          WITH_TRIVY = "false";
          REGISTRY_CREDENTIAL_USERNAME = registryUser;
          PORT = "8080";
          QUOTA_UPDATE_PROVIDER = "db";
          DATABASE_TYPE = "postgresql";
          POSTGRESQL_HOST = database.out.host;
          POSTGRESQL_PORT = database.out.port;
          POSTGRESQL_USERNAME = database.out.username;
          POSTGRESQL_DATABASE = database.out.database;
          POSTGRESQL_SSLMODE = sslmode;
          CHART_CACHE_DRIVER = "redis";
          "app.conf" = ''
            appname = Harbor
            runmode = prod
            enablegzip = true
            [prod]
            httpport = 8080'';
        }
        // lib.optionalAttrs metricsEnabled {
          METRIC_ENABLE = "true";
          METRIC_NAMESPACE = "harbor";
          METRIC_PATH = "/metrics";
          METRIC_PORT = toString metricsPort;
          METRIC_SUBSYSTEM = "core";
        };

        jobserviceEnvData = {
          CORE_URL = coreUrl;
          TOKEN_SERVICE_URL = tokenServiceUrl;
          REGISTRY_URL = registryUrl;
          REGISTRY_CONTROLLER_URL = registryCtlUrl;
          REGISTRY_CREDENTIAL_USERNAME = registryUser;
        }
        // lib.optionalAttrs metricsEnabled {
          METRIC_NAMESPACE = "harbor";
          METRIC_SUBSYSTEM = "jobservice";
        };

        exporterEnvData = {
          HARBOR_DATABASE_DBNAME = database.out.database;
          HARBOR_DATABASE_HOST = database.out.host;
          HARBOR_DATABASE_PORT = database.out.port;
          HARBOR_DATABASE_USERNAME = database.out.username;
          HARBOR_DATABASE_SSLMODE = sslmode;
          HARBOR_EXPORTER_METRICS_ENABLED = "true";
          HARBOR_EXPORTER_METRICS_PATH = "/metrics";
          HARBOR_EXPORTER_PORT = toString metricsPort;
          HARBOR_METRIC_NAMESPACE = "harbor";
          HARBOR_METRIC_SUBSYSTEM = "exporter";
          HARBOR_REDIS_NAMESPACE = "harbor_job_service_namespace";
          HARBOR_REDIS_TIMEOUT = "3600";
          HARBOR_SERVICE_HOST = self.coreService.out.fqdn;
          HARBOR_SERVICE_PORT = self.coreService.out.port;
          HARBOR_SERVICE_SCHEME = "http";
        };

        # --- Registry config.yml ---
        registryStorageKeys = [
          "cache"
          "maintenance"
          "delete"
          "redirect"
          "tag"
        ];
        badStorageKeys = builtins.filter (k: !(builtins.elem k registryStorageKeys)) (
          builtins.attrNames (config.registry.settings.storage or { })
        );
        registryConfig =
          if badStorageKeys != [ ] then
            throw "${who}: registry.settings.storage sets ${lib.concatStringsSep ", " badStorageKeys}, a storage driver or an unknown key. This package stores blobs on the storage claim with the filesystem driver; object storage is not supported. registry.settings.storage accepts ${lib.concatStringsSep ", " registryStorageKeys}."
          else
            lib.filterAttrsRecursive (_: v: v != null) (
              kix.mergeGuarded
                {
                  inherit who;
                  what = "registry.settings";
                  locked = [
                    [
                      "storage"
                      "filesystem"
                    ]
                    [
                      "redis"
                      "addr"
                    ]
                    [
                      "redis"
                      "db"
                    ]
                    [
                      "redis"
                      "sentinelMasterSet"
                    ]
                    [
                      "redis"
                      "password"
                    ]
                    [
                      "http"
                      "addr"
                    ]
                    [
                      "http"
                      "debug"
                    ]
                    [ "auth" ]
                  ];
                }
                {
                  version = "0.1";
                  log = {
                    level = "info";
                    fields.service = "registry";
                  };
                  storage = {
                    filesystem.rootdirectory = "/storage";
                    cache.layerinfo = "redis";
                    maintenance.uploadpurging = {
                      enabled = true;
                      age = "168h";
                      interval = "24h";
                      dryrun = false;
                    };
                    delete.enabled = true;
                    redirect.disable = false;
                  };
                  # The password arrives as REGISTRY_REDIS_PASSWORD;
                  # distribution reads REGISTRY_* env over the file.
                  redis = {
                    addr = redisAddr;
                    db = 2;
                    readtimeout = "10s";
                    writetimeout = "10s";
                    dialtimeout = "10s";
                    pool = {
                      maxidle = 100;
                      maxactive = 500;
                      idletimeout = "60s";
                    };
                  }
                  // lib.optionalAttrs redisSentinel { sentinelMasterSet = valkey.out.primarySet; };
                  http = {
                    addr = ":5000";
                    relativeurls = false;
                    debug = {
                      addr = ":${toString metricsPort}";
                      prometheus = {
                        enabled = metricsEnabled;
                        path = "/metrics";
                      };
                    };
                  };
                  auth.htpasswd = {
                    realm = "harbor-registry-basic-realm";
                    path = "/etc/registry-auth/passwd";
                  };
                  validation.disabled = true;
                  compatibility.schema1.enabled = true;
                }
                config.registry.settings
            );

        # --- Jobservice config.yml ---
        # The redis URL arrives as JOB_SERVICE_POOL_REDIS_URL, because it
        # carries the password; jobservice reads JOB_SERVICE_* env over the
        # file. The DB job logger keeps every job's log in the database, so
        # any jobservice pod can serve it.
        jobserviceConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded
            {
              inherit who;
              what = "jobservice.settings";
              locked = [
                [ "protocol" ]
                [ "port" ]
                [
                  "worker_pool"
                  "backend"
                ]
                # The exporter reads job queues under this namespace.
                [
                  "worker_pool"
                  "redis_pool"
                  "namespace"
                ]
                [
                  "worker_pool"
                  "redis_pool"
                  "redis_url"
                ]
                [ "job_loggers" ]
                [ "metric" ]
              ];
            }
            {
              protocol = "http";
              port = 8080;
              worker_pool = {
                workers = 10;
                backend = "redis";
                redis_pool = {
                  namespace = "harbor_job_service_namespace";
                  idle_timeout_second = 3600;
                };
              };
              job_loggers = [
                {
                  name = "STD_OUTPUT";
                  level = "INFO";
                }
                {
                  name = "DB";
                  level = "INFO";
                  sweeper.duration = 14;
                }
              ];
              metric = {
                enabled = metricsEnabled;
                path = "/metrics";
                port = metricsPort;
              };
              loggers = [
                {
                  name = "STD_OUTPUT";
                  level = "INFO";
                }
              ];
              reaper = {
                max_update_hours = 24;
                max_dangling_hours = 168;
              };
            }
            config.jobservice.settings
        );
      in
      {
        # ============================================================
        # Core: API server, auth, project management
        # ============================================================

        coreConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-core";
          data = coreConfigData;
        };

        # Not fromWorkload: core's own config carries CORE_URL, so a core
        # Service with the core Deployment's context would recurse (core
        # Deployment -> core ConfigMap -> core Service -> core Deployment).
        # The selector is the same literal the Deployment is built from, so
        # they cannot drift; root.requires restores the ordering edge to
        # the core Deployment.
        coreService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = svc.core;
          labels = componentLabels "core";
          spec = {
            selector = coreSelector;
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = 8080;
                protocol = "TCP";
              }
            ]
            ++ metricsServicePort;
          };
          outputs.port = "80";
        };

        coreDeployment =
          {
            name = "${name}-core";
            labels = componentSelector "core";
            spec = {
              replicas = config.core.replicas;
              revisionHistoryLimit = 5;
              selector.matchLabels = coreSelector;
              template.metadata.annotations = {
                "checksum/config" = self.coreConfigMap.out.identityHash;
              }
              // checksumOf "harbor-secrets" secrets
              // checksumOf "database-credentials" dbCredentials
              // valkeyChecksum;
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "core";
                    image = kix.image.ref config.core.image;
                    command = [ "/harbor/harbor_core" ];
                    imagePullPolicy = config.core.image.pullPolicy;
                    livenessProbe = coreProbe;
                    readinessProbe = coreProbe;
                    startupProbe = coreProbe // {
                      initialDelaySeconds = 10;
                      failureThreshold = 360;
                    };
                    envFrom = [ { configMapRef.name = self.coreConfigMap.out.name; } ];
                    env = componentEnv {
                      option = "core.env";
                      secretEnv =
                        secrets.out.mkEnv {
                          HARBOR_ADMIN_PASSWORD = "adminPassword";
                          CORE_SECRET = "coreSecret";
                          JOBSERVICE_SECRET = "jobserviceSecret";
                          CSRF_KEY = "csrfKey";
                          REGISTRY_CREDENTIAL_PASSWORD = "registryPassword";
                        }
                        ++ dbPasswordEnv "POSTGRESQL_PASSWORD"
                        ++ redisPasswordEnv;
                      facts = builtins.attrNames coreConfigData;
                      sslmodeVar = "POSTGRESQL_SSLMODE";
                      vars = {
                        _REDIS_URL_CORE = "${redisUrl 0}?idle_timeout_seconds=30";
                        _REDIS_URL_REG = "${redisUrl 2}?idle_timeout_seconds=30";
                      };
                      tunables = {
                        LOG_LEVEL = "info";
                        PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE = "docker-hub,harbor,azure-acr,ali-acr,aws-ecr,google-gcr,docker-registry,github-ghcr,jfrog-artifactory";
                        REPLICATION_ADAPTER_WHITELIST = "ali-acr,aws-ecr,azure-acr,docker-hub,docker-registry,github-ghcr,google-gcr,harbor,huawei-SWR,jfrog-artifactory,tencent-tcr,volcengine-cr";
                        POSTGRESQL_MAX_IDLE_CONNS = "100";
                        POSTGRESQL_MAX_OPEN_CONNS = "900";
                      };
                      env = config.core.env;
                    };
                    ports = [ (kix.port "http" 8080) ] ++ metricsContainerPort;
                    resources = config.core.resources;
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.configMap self.coreConfigMap {
              name = "config";
              mountPath = "/etc/core/app.conf";
              subPath = "app.conf";
              items = [
                {
                  key = "app.conf";
                  path = "app.conf";
                }
              ];
            })
            (kix.mount.secret secrets {
              name = "secret-key";
              mountPath = "/etc/core/key";
              subPath = "key";
              items = [
                {
                  key = "secretKey";
                  path = "key";
                }
              ];
              defaultMode = 420;
            })
            (kix.mount.secret secrets {
              name = "token-service-private-key";
              mountPath = "/etc/core/private_key.pem";
              subPath = "private_key.pem";
              items = [
                {
                  key = "tokenPrivateKey";
                  path = "private_key.pem";
                }
              ];
              defaultMode = 420;
            })
            (kix.mount.emptyDir {
              name = "ca-download";
              mountPath = "/etc/core/ca";
            })
            (kix.mount.emptyDir {
              name = "psc";
              mountPath = "/etc/core/token";
            })
            (tmpMount "tmp")
            caBundleMount
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Portal: web UI (nginx)
        # ============================================================

        portalConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-portal";
          data = {
            "nginx.conf" = ''
              worker_processes auto;
              pid /tmp/nginx.pid;
              events {
                  worker_connections  1024;
              }
              http {
                  client_body_temp_path /tmp/client_body_temp;
                  proxy_temp_path /tmp/proxy_temp;
                  fastcgi_temp_path /tmp/fastcgi_temp;
                  uwsgi_temp_path /tmp/uwsgi_temp;
                  scgi_temp_path /tmp/scgi_temp;
                  server {
                      listen 8080;
                      listen [::]:8080;
                      server_name  localhost;
                      root   /usr/share/nginx/html;
                      index  index.html index.htm;
                      include /etc/nginx/mime.types;
                      gzip on;
                      gzip_min_length 1000;
                      gzip_proxied expired no-cache no-store private auth;
                      gzip_types text/plain text/css application/json application/javascript application/x-javascript text/xml application/xml application/xml+rss text/javascript;
                      location /devcenter-api-2.0 {
                          try_files $uri $uri/ /swagger-ui-index.html;
                      }
                      location / {
                          try_files $uri $uri/ /index.html;
                      }
                      location = /index.html {
                          add_header Cache-Control "no-store, no-cache, must-revalidate";
                      }
                  }
              }'';
          };
        };

        portalService =
          self.portalDeployment
          |> kix.service.fromWorkload {
            name = svc.portal;
            labels = componentLabels "portal";
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = 8080;
                protocol = "TCP";
              }
            ];
            outputs.port = "80";
          }
          |> scope.mkResource;

        portalDeployment =
          {
            name = "${name}-portal";
            labels = componentSelector "portal";
            spec = {
              replicas = config.portal.replicas;
              revisionHistoryLimit = 5;
              selector.matchLabels = componentSelector "portal";
              template.metadata.annotations = {
                "checksum/config" = self.portalConfigMap.out.identityHash;
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "portal";
                    image = kix.image.ref config.portal.image;
                    imagePullPolicy = config.portal.image.pullPolicy;
                    ports = [ (kix.port "http" 8080) ];
                    livenessProbe = portalProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = portalProbe // {
                      initialDelaySeconds = 1;
                    };
                    resources = config.portal.resources;
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.configMap self.portalConfigMap {
              name = "portal-config";
              mountPath = "/etc/nginx/nginx.conf";
              subPath = "nginx.conf";
            })
            # nginx.conf puts the pid file and every temp path under /tmp.
            (tmpMount "tmp")
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Registry: OCI blob storage, plus the registryctl sidecar
        # ============================================================

        registryConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-registry";
          data = {
            # JSON is YAML, and distribution reads it as such.
            "config.yml" = builtins.toJSON registryConfig;
            "ctl-config.yml" = ''
              ---
              protocol: "http"
              port: 8080
              log_level: info
              registry_config: "/etc/registry/config.yml"
            '';
          };
        };

        registryService =
          self.registryDeployment
          |> kix.service.fromWorkload {
            name = svc.registry;
            labels = componentLabels "registry";
            ports = [
              {
                name = "http-registry";
                port = 5000;
                targetPort = 5000;
                protocol = "TCP";
              }
              {
                name = "http-controller";
                port = 8080;
                targetPort = 8080;
                protocol = "TCP";
              }
            ]
            ++ metricsServicePort;
            outputs.port = "5000";
          }
          |> scope.mkResource;

        registryDeployment =
          let
            # Shared volumes are injected once, on the registry container;
            # registryctl and the init container mount them by name.
            configMount = kix.mount.configMap self.registryConfigMap {
              name = "registry-config";
              mountPath = "/etc/registry/config.yml";
              subPath = "config.yml";
            };
            dataMount = kix.mount.pvc storage {
              name = "registry-data";
              mountPath = "/storage";
            };
            authMount = kix.mount.emptyDir {
              name = "registry-auth";
              mountPath = "/etc/registry-auth";
            };
            registryEnv =
              secrets.out.mkEnv { REGISTRY_HTTP_SECRET = "registryHttpSecret"; }
              ++ lib.optional redisAuth (redisPasswordRef "REGISTRY_REDIS_PASSWORD")
              ++ kix.mkEnvVars caTrust;
          in
          {
            name = "${name}-registry";
            labels = componentSelector "registry";
            # The blob claim is ReadWriteOnce and the filesystem driver keeps
            # upload state on it, so a second pod has no volume of its own.
            availability.max = "none";
            spec = {
              replicas = 1;
              revisionHistoryLimit = 5;
              strategy.type = "Recreate";
              selector.matchLabels = componentSelector "registry";
              template.metadata.annotations = {
                "checksum/config" = self.registryConfigMap.out.identityHash;
              }
              // checksumOf "harbor-secrets" secrets
              // valkeyChecksum;
              template.spec = harborPodDefaults // {
                securityContext = harborPodDefaults.securityContext // {
                  fsGroupChangePolicy = "OnRootMismatch";
                };
                # The registry checks core's and jobservice's basic auth
                # against a bcrypt htpasswd line. Nix has no bcrypt, and a
                # SOPS value is not readable at evaluation, so this
                # container computes the line from registryPassword when the
                # pod starts. `-i` reads the password from stdin, which keeps
                # it out of the process arguments.
                initContainers = [
                  {
                    name = "htpasswd";
                    image = kix.image.ref config.htpasswd.image;
                    imagePullPolicy = config.htpasswd.image.pullPolicy;
                    command = [
                      "/bin/sh"
                      "-c"
                      ''printf '%s' "$REGISTRY_PASSWORD" | htpasswd -niB ${registryUser} > /etc/registry-auth/passwd''
                    ];
                    env = secrets.out.mkEnv { REGISTRY_PASSWORD = "registryPassword"; };
                    volumeMounts = [
                      {
                        name = authMount.name;
                        mountPath = "/etc/registry-auth";
                      }
                    ];
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits = {
                        cpu = "100m";
                        memory = "64Mi";
                      };
                    };
                    securityContext = containerSecurityContext;
                  }
                ];
                containers = [
                  {
                    name = "registry";
                    image = kix.image.ref config.registry.image;
                    command = [ "/usr/bin/registry_DO_NOT_USE_GC" ];
                    args = [
                      "serve"
                      "/etc/registry/config.yml"
                    ];
                    imagePullPolicy = config.registry.image.pullPolicy;
                    ports = [ (kix.port "registry" 5000) ] ++ metricsContainerPort;
                    livenessProbe = registryProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = registryProbe // {
                      initialDelaySeconds = 1;
                    };
                    env = registryEnv;
                    resources = config.registry.resources;
                    securityContext = containerSecurityContext;
                  }
                  {
                    name = "registryctl";
                    image = kix.image.ref config.registryctl.image;
                    command = [ "/home/harbor/harbor_registryctl" ];
                    args = [
                      "-c"
                      "/etc/registryctl/config.yml"
                    ];
                    imagePullPolicy = config.registryctl.image.pullPolicy;
                    ports = [ (kix.port "registryctl" 8080) ];
                    livenessProbe = registryCtlProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = registryCtlProbe // {
                      initialDelaySeconds = 1;
                    };
                    env =
                      registryEnv
                      ++ secrets.out.mkEnv {
                        CORE_SECRET = "coreSecret";
                        JOBSERVICE_SECRET = "jobserviceSecret";
                      };
                    volumeMounts = [
                      {
                        name = configMount.name;
                        mountPath = "/etc/registry/config.yml";
                        subPath = "config.yml";
                      }
                      {
                        name = configMount.name;
                        mountPath = "/etc/registryctl/config.yml";
                        subPath = "ctl-config.yml";
                      }
                      {
                        name = dataMount.name;
                        mountPath = "/storage";
                      }
                    ]
                    # The registry container's withMountsOn below adds the
                    # volume itself.
                    ++ lib.optional (caBundleMount != null) {
                      inherit (caBundleMount) name mountPath subPath;
                    };
                    resources = config.registryctl.resources;
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
          }
          |> kix.withMountsOn "registry" [
            configMount
            authMount
            dataMount
            (tmpMount "registry-tmp")
            caBundleMount
          ]
          |> kix.withMountsOn "registryctl" [ (tmpMount "registryctl-tmp") ]
          |> scope.mkDeployment;

        # ============================================================
        # Jobservice: async jobs (replication, GC, retention)
        # ============================================================

        jobserviceConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice";
          data."config.yml" = builtins.toJSON jobserviceConfig;
        };

        jobserviceEnvConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice-env";
          data = jobserviceEnvData;
        };

        # Not fromWorkload either: core's ConfigMap carries the jobservice
        # URL, and a jobservice Service with the jobservice Deployment's
        # context would order core after jobservice. That is backwards:
        # jobservice fetches its configuration from core's API on boot and
        # panics until core answers, so it must start after core, which the
        # explicit `requires` on the jobservice Deployment below states.
        # Same literal-selector trade as the core Service.
        jobserviceService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = svc.jobservice;
          labels = componentLabels "jobservice";
          spec = {
            selector = jobserviceSelector;
            ports = [
              {
                name = "http-jobservice";
                port = 80;
                targetPort = 8080;
                protocol = "TCP";
              }
            ]
            ++ metricsServicePort;
          };
          outputs.port = "80";
        };

        jobserviceDeployment =
          {
            name = "${name}-jobservice";
            labels = componentSelector "jobservice";
            # Boot order, not a data edge: see the jobservice Service.
            requires = [ self.coreDeployment ];
            spec = {
              replicas = config.jobservice.replicas;
              revisionHistoryLimit = 5;
              selector.matchLabels = jobserviceSelector;
              template.metadata.annotations = {
                "checksum/config" = self.jobserviceConfigMap.out.identityHash;
                "checksum/env" = self.jobserviceEnvConfigMap.out.identityHash;
              }
              // checksumOf "harbor-secrets" secrets
              // checksumOf "database-credentials" dbCredentials
              // valkeyChecksum;
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "jobservice";
                    image = kix.image.ref config.jobservice.image;
                    command = [ "/harbor/harbor_jobservice" ];
                    args = [
                      "-c"
                      "/etc/jobservice/config.yml"
                    ];
                    imagePullPolicy = config.jobservice.image.pullPolicy;
                    ports = [ (kix.port "http" 8080) ] ++ metricsContainerPort;
                    livenessProbe = jobserviceProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = jobserviceProbe // {
                      initialDelaySeconds = 20;
                    };
                    envFrom = [ { configMapRef.name = self.jobserviceEnvConfigMap.out.name; } ];
                    # jobservice takes its database settings from core's
                    # internalconfig API, but it dials PostgreSQL itself
                    # (the DB job logger among others), so the database
                    # facts appear here for the netpol egress edge.
                    env =
                      componentEnv {
                        option = "jobservice.env";
                        secretEnv =
                          secrets.out.mkEnv {
                            CORE_SECRET = "coreSecret";
                            JOBSERVICE_SECRET = "jobserviceSecret";
                            REGISTRY_CREDENTIAL_PASSWORD = "registryPassword";
                          }
                          ++ dbPasswordEnv "POSTGRESQL_PASSWORD"
                          ++ redisPasswordEnv;
                        facts = builtins.attrNames jobserviceEnvData;
                        sslmodeVar = "POSTGRESQL_SSLMODE";
                        vars = {
                          POSTGRESQL_HOST = database.out.host;
                          POSTGRESQL_PORT = database.out.port;
                          POSTGRESQL_USERNAME = database.out.username;
                          POSTGRESQL_DATABASE = database.out.database;
                          JOB_SERVICE_POOL_REDIS_URL = redisUrl 1;
                        };
                        tunables = {
                          LOG_LEVEL = "info";
                          REGISTRY_HTTP_CLIENT_TIMEOUT = "30";
                          JOBSERVICE_WEBHOOK_JOB_MAX_RETRY = "3";
                          JOBSERVICE_WEBHOOK_JOB_HTTP_CLIENT_TIMEOUT = "3";
                        };
                        env = config.jobservice.env;
                      }
                      ++ kix.mkEnvVars { POSTGRESQL_SSLMODE = sslmode; };
                    resources = config.jobservice.resources;
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.configMap self.jobserviceConfigMap {
              name = "jobservice-config";
              mountPath = "/etc/jobservice/config.yml";
              subPath = "config.yml";
            })
            (tmpMount "tmp")
            caBundleMount
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Exporter: Harbor-wide metrics (with metrics only)
        # ============================================================

        exporterEnvConfigMap =
          if !metricsEnabled then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-exporter-env";
              data = exporterEnvData;
            };

        exporterService =
          if !metricsEnabled then
            null
          else
            self.exporterDeployment
            |> kix.service.fromWorkload {
              name = svc.exporter;
              labels = componentLabels "exporter";
              ports = metricsServicePort;
            }
            |> scope.mkResource;

        exporterDeployment =
          if !metricsEnabled then
            null
          else
            {
              name = "${name}-exporter";
              labels = componentSelector "exporter";
              # Every exporter reports the same Harbor-wide gauges, so a
              # second pod doubles every sum() over them.
              availability.max = "none";
              spec = {
                replicas = 1;
                revisionHistoryLimit = 5;
                selector.matchLabels = componentSelector "exporter";
                template.metadata.annotations = {
                  "checksum/env" = self.exporterEnvConfigMap.out.identityHash;
                }
                // checksumOf "harbor-secrets" secrets
                // checksumOf "database-credentials" dbCredentials
                // valkeyChecksum;
                template.spec = harborPodDefaults // {
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    {
                      name = "exporter";
                      image = kix.image.ref config.exporter.image;
                      imagePullPolicy = config.exporter.image.pullPolicy;
                      command = [ "/harbor/harbor_exporter" ];
                      ports = metricsContainerPort;
                      livenessProbe = exporterProbe // {
                        initialDelaySeconds = 300;
                      };
                      readinessProbe = exporterProbe // {
                        initialDelaySeconds = 30;
                      };
                      envFrom = [ { configMapRef.name = self.exporterEnvConfigMap.out.name; } ];
                      env = componentEnv {
                        option = "exporter.env";
                        secretEnv =
                          secrets.out.mkEnv { HARBOR_ADMIN_PASSWORD = "adminPassword"; }
                          ++ dbPasswordEnv "HARBOR_DATABASE_PASSWORD"
                          ++ redisPasswordEnv;
                        facts = builtins.attrNames exporterEnvData;
                        sslmodeVar = "HARBOR_DATABASE_SSLMODE";
                        vars.HARBOR_REDIS_URL = redisUrl 1;
                        tunables = {
                          LOG_LEVEL = "info";
                          HARBOR_DATABASE_MAX_IDLE_CONNS = "100";
                          HARBOR_DATABASE_MAX_OPEN_CONNS = "900";
                          HARBOR_EXPORTER_CACHE_TIME = "23";
                          HARBOR_EXPORTER_CACHE_CLEAN_INTERVAL = "14400";
                        };
                        env = config.exporter.env;
                      };
                      resources = config.exporter.resources;
                      securityContext = containerSecurityContext;
                    }
                  ];
                };
              };
            }
            |> kix.withMounts [
              (tmpMount "tmp")
              caBundleMount
            ]
            |> scope.mkDeployment;

        # ============================================================
        # Entry point
        # ============================================================

        # Reachable through the route: the core and portal Services.
        # Neither the core nor the jobservice Service carries a workload
        # edge (see above), so both Deployments are listed here; core's
        # ConfigMap reaches every other component. The exporter and the
        # monitors hang off nothing.
        root = {
          resource = if self.route != null then self.route else self.coreService;
          requires = builtins.filter (r: r != null) [
            self.coreDeployment
            self.jobserviceDeployment
            self.exporterService
            self.coreMonitor
            self.coreAlerts
            self.registryMonitor
            self.jobserviceMonitor
            self.exporterMonitor
          ];
        };
      }
    )

    # API paths route to core, everything else to the portal. A layer
    # upload outlasts a Gateway's 15s default request timeout, and Gateway
    # API reads "0s" as no timeout.
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

    # One ServiceMonitor per metrics Service. The alert rules ride on the
    # core entry; they cover every component.
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
