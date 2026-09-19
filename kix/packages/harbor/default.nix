# Harbor container registry kix package.
#
# Multi-component OCI registry: Core (API/auth), Portal (web UI),
# Registry (blob storage, with the registryctl sidecar), Jobservice
# (async tasks) and Exporter (metrics). The database and the cache are
# DI deps, not sub-components (BEST-PRACTICES §12.5).
#
# Dependencies:
#   database       — required, logical postgres database. stackgres-database,
#                    or anything exposing out.{host,port,database,username,
#                    credentials} with a `password` key on the credentials.
#   valkey         — required, Redis-compatible cache and job queue
#                    (packages/valkey answers both `valkey` and `redis`).
#   storage        — required, persistent volume for registry blobs.
#   clusterIssuer  — optional. TLS on the Ingress (via kix.expose) and the
#                    scheme of the derived external URL.
#   ingressNginx / gateway — optional, exposure (via kix.expose).
#   prometheus     — optional, ServiceMonitors + PrometheusRule (via kix.monitor).
#
# Secrets: one kix-managed Secret (the `credentials` part) holds every credential Harbor needs
# (see `secretKeys` below). Point `secrets.source` at a SOPS file, or set
# `secrets.values` inline on a dev cluster. There are no defaults.
#
# Internal wiring: every component dials the others through
# `self.<service>.out.fqdn`, so the DAG, netpol egress and deploy ordering
# all follow from the manifests. Core and jobservice dial each other, which
# would be a store-path cycle, so the core Service is the one Service whose
# selector is a literal rather than the Deployment's `out.selector`
# (BEST-PRACTICES §7.3); everything else reaches core through it, and
# `root.requires` pulls in the core Deployment.
#
# root = Ingress when exposed, otherwise the core Service.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  harborVersion = "v2.12.2";

  # Keys of the `${name}-secrets` Secret. `registryHtpasswd` is the bcrypt
  # htpasswd line for `registryUser` with `registryPassword`, e.g.
  # `htpasswd -nbB harbor_registry_user <password>`.
  secretKeys = [
    "adminPassword" # initial admin login (HARBOR_ADMIN_PASSWORD)
    "secretKey" # 16 chars, encrypts credentials Harbor stores in the DB
    "coreSecret" # CORE_SECRET: core <-> jobservice/registryctl auth
    "jobserviceSecret" # JOBSERVICE_SECRET
    "csrfKey" # CSRF_KEY, 32 chars
    "registryHttpSecret" # REGISTRY_HTTP_SECRET, registry upload state
    "registryPassword" # core/jobservice -> registry basic auth
    "registryHtpasswd" # htpasswd line the registry checks that password against
    "tokenPrivateKey" # RSA private key PEM, signs registry bearer tokens
  ];
  registryUser = "harbor_registry_user";

  mkComponent =
    {
      repository,
      requests,
      limits,
    }:
    {
      image = kix.options.image {
        inherit repository;
        tag = harborVersion;
      };
      resources = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {
          inherit requests limits;
        };
      };
    };

  alerts = {
    HarborHealthCheckFailed = {
      expr = "harbor_health == 0";
      "for" = "5m";
      severity = "critical";
      summary = "Harbor health check failed";
      description = "Harbor instance {{ $labels.instance }} health check is failing.";
    };
    HarborCoreHighInflightRequests = {
      expr = "harbor_core_http_inflight_requests > 100";
      "for" = "10m";
      severity = "warning";
      summary = "High number of inflight requests in Harbor Core";
      description = "Harbor Core instance {{ $labels.instance }} has more than 100 inflight requests.";
    };
    HarborCoreHighRequestDuration = {
      expr = "(sum by (method, instance) (rate(harbor_core_http_request_duration_seconds_sum[1m])) / sum by (method, instance) (rate(harbor_core_http_request_duration_seconds_count[1m]))) > 1";
      "for" = "10m";
      severity = "warning";
      summary = "High request duration in Harbor Core";
      description = "Harbor Core instance {{ $labels.instance }} has an average {{ $labels.method }} request duration of more than 1 second.";
    };
    HarborCoreHttp5xxRequestErrors = {
      expr = ''sum(rate(harbor_core_http_request_total{code=~"5.."}[5m])) / sum(rate(harbor_core_http_request_total[5m])) > 0.1'';
      "for" = "10m";
      severity = "critical";
      summary = "High rate of HTTP 5xx errors in Harbor Core";
      description = "Harbor Core instance {{ $labels.instance }} is experiencing more than 10% HTTP 5xx errors.";
    };
    HarborCoreHttp4xxRequestErrors = {
      expr = ''sum(rate(harbor_core_http_request_total{code=~"4.."}[5m])) / sum(rate(harbor_core_http_request_total[5m])) > 0.3'';
      "for" = "10m";
      severity = "critical";
      summary = "High rate of HTTP 4xx errors in Harbor Core";
      description = "Harbor Core instance {{ $labels.instance }} is experiencing more than 30% HTTP 4xx errors.";
    };
    HarborProjectQuotaUsageHigh = {
      expr = "(harbor_project_quota_usage_byte / harbor_project_quota_byte) > 0.8";
      "for" = "10m";
      severity = "warning";
      summary = "High quota usage in Harbor project";
      description = "Quota usage in Harbor project {{ $labels.project_name }} is above 80%.";
    };
    HarborTaskQueueSizeHigh = {
      expr = "harbor_task_queue_size > 20";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue size in Harbor";
      description = "Harbor instance {{ $labels.instance }} has more than 20 tasks in the queue.";
    };
    HarborTaskQueueLatencyHigh = {
      expr = "harbor_task_queue_latency > 60";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue latency in Harbor";
      description = "Harbor instance {{ $labels.instance }} has a task queue latency of more than 60 seconds.";
    };
    HarborTaskConcurrencyHigh = {
      expr = "harbor_task_concurrency > 10";
      "for" = "10m";
      severity = "warning";
      summary = "High task concurrency in Harbor";
      description = "Harbor instance {{ $labels.instance }} is running more than 10 tasks concurrently.";
    };
    HarborInstanceDown = {
      # The job label is the scraped Service's name (`<instance>-core`, ...).
      expr = ''up{job=~"${name}-.*"} == 0'';
      "for" = "5m";
      severity = "critical";
      summary = "Harbor component is down";
      description = "Harbor target {{ $labels.job }} ({{ $labels.instance }}) is down.";
    };
  };
in
{
  meta = {
    version = harborVersion;
    description = "Harbor — OCI container registry";
    # The ingress controller has to reach core and portal, and kix.expose
    # gives it no netpol edge yet (housekeeping: no-netpol-edge-from-
    # ingress-controller). Until it does, the web port accepts any pod in
    # the cluster, which a registry wants anyway: in-cluster clients pull
    # through the same Service the Ingress fronts. Every request past
    # this port is still authenticated by core.
    network.intents.in-cluster-clients = {
      ingress = [
        {
          from = "all-pods";
          ports = [
            {
              port = 8080;
              protocol = "TCP";
            }
          ];
        }
      ];
    };
  };

  options = {
    externalURL = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public URL clients use (EXT_ENDPOINT). Null derives it from the ingress host: https when a clusterIssuer is wired, http otherwise.";
    };

    core =
      mkComponent {
        repository = "goharbor/harbor-core";
        requests = {
          cpu = "20m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      }
      // {
        replicas = lib.mkOption {
          type = lib.types.int;
          default = 1;
        };
      };

    portal =
      mkComponent {
        repository = "goharbor/harbor-portal";
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      }
      // {
        replicas = lib.mkOption {
          type = lib.types.int;
          default = 1;
        };
      };

    registry = mkComponent {
      repository = "goharbor/registry-photon";
      requests = {
        cpu = "20m";
        memory = "64Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    registryctl = mkComponent {
      repository = "goharbor/harbor-registryctl";
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };

    jobservice =
      mkComponent {
        repository = "goharbor/harbor-jobservice";
        requests = {
          cpu = "20m";
          memory = "128Mi";
        };
        limits = {
          cpu = "2";
          memory = "1Gi";
        };
      }
      // {
        replicas = lib.mkOption {
          type = lib.types.int;
          default = 1;
        };
        workers = lib.mkOption {
          type = lib.types.int;
          default = 10;
        };
      };

    exporter = mkComponent {
      repository = "goharbor/harbor-exporter";
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };

    metrics = kix.options.monitor // {
      port = lib.mkOption {
        type = lib.types.int;
        default = 8001;
        description = "Port every component serves /metrics on. The exporter only exists when metrics are enabled.";
      };
    };

    database = {
      sslmode = lib.mkOption {
        type = lib.types.str;
        default = "require";
      };
      maxIdleConns = lib.mkOption {
        type = lib.types.int;
        default = 100;
      };
      maxOpenConns = lib.mkOption {
        type = lib.types.int;
        default = 900;
      };
    };

    ingress = kix.options.ingress;

    secrets = {
      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "SOPS-encrypted file holding every key in the package's `secretKeys` list. Decrypted by `kix deploy` at apply time.";
      };
      hash = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Content hash of `source`, for change detection.";
      };
      values = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        description = "Inline secret values, dev clusters only. Same keys as `source`.";
      };
    };
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
        clusterIssuer ? null,
        ...
      }:
      let
        metricsEnabled = config.metrics.enabled;
        metricsPort = config.metrics.port;

        # --- Public URL ---
        clusterDomain = clusterConfig.cluster.domain or null;
        effectiveHost =
          if config.ingress.host != null then
            config.ingress.host
          else if clusterDomain != null then
            "${name}.${clusterDomain}"
          else
            null;
        externalURL =
          if config.externalURL != null then
            config.externalURL
          else if effectiveHost != null then
            "${if clusterIssuer != null then "https" else "http"}://${effectiveHost}"
          else
            throw "harbor (${name}): set `externalURL`, `ingress.host` or `cluster.domain` so Harbor knows the URL clients reach it on.";

        # --- Secrets ---
        _secretsCheck =
          if config.secrets.source == null && config.secrets.values == null then
            throw "harbor (${name}): set `secrets.source` (a SOPS file) or `secrets.values` (inline, dev only). Required keys: ${lib.concatStringsSep ", " secretKeys}."
          else if config.secrets.values != null then
            let
              missing = builtins.filter (k: !(config.secrets.values ? ${k})) secretKeys;
            in
            if missing != [ ] then
              throw "harbor (${name}): `secrets.values` is missing ${lib.concatStringsSep ", " missing}."
            else
              null
          else
            null;

        # --- Internal addresses ---
        # `out.fqdn` carries the endpoint fact: the consuming pod gets the
        # netpol egress and waits for the Service. Bare `<name>-core` strings
        # would carry neither.
        coreUrl = "http://${self.coreService.out.fqdn}:${self.coreService.out.port}";
        tokenServiceUrl = "${coreUrl}/service/token";
        portalUrl = "http://${self.portalService.out.fqdn}:${self.portalService.out.port}";
        registryUrl = "http://${self.registryService.out.fqdn}:5000";
        registryCtlUrl = "http://${self.registryService.out.fqdn}:8080";
        jobserviceUrl = "http://${self.jobserviceService.out.fqdn}:${self.jobserviceService.out.port}";

        # Valkey. The password rides in as an env var from valkey's own
        # Secret and is spliced into the URL by Kubernetes' $(VAR) expansion,
        # so no ConfigMap ever carries it.
        redisAuth = valkey.out ? authSecret;
        redisAddr = "${valkey.out.fqdn}:${valkey.out.port}";
        redisUrl =
          db: "redis://${lib.optionalString redisAuth ":$(REDIS_PASSWORD)@"}${redisAddr}/${toString db}";
        redisPasswordEnv = lib.optionals redisAuth [
          (valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey // { name = "REDIS_PASSWORD"; })
        ];

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
          runAsNonRoot = true;
          seccompProfile.type = "RuntimeDefault";
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
        # overrides httpGet. Sites add initialDelaySeconds with //.
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
      in
      {
        # ============================================================
        # Secrets
        # ============================================================

        credentials = builtins.seq _secretsCheck (
          scope.mkSecret {
            name = "${name}-secrets";
            keys = secretKeys;
            stringData = if config.secrets.values != null then config.secrets.values else { };
            source = config.secrets.source;
            hash = config.secrets.hash;
            meta = {
              classification = "credential";
              rotationPolicy = "manual";
            };
          }
        );

        # ============================================================
        # Core -- API server, auth, project management
        # ============================================================

        coreConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-core";
          data = {
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
            POSTGRESQL_SSLMODE = config.database.sslmode;
            POSTGRESQL_MAX_IDLE_CONNS = toString config.database.maxIdleConns;
            POSTGRESQL_MAX_OPEN_CONNS = toString config.database.maxOpenConns;
            PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE = "docker-hub,harbor,azure-acr,aws-ecr,google-gcr,quay,docker-registry,github-ghcr,jfrog-artifactory";
            LOG_LEVEL = "info";
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
        };

        # Not fromWorkload: core's own config carries CORE_URL, so a core
        # Service with the core Deployment's context would recurse (core
        # Deployment -> core ConfigMap -> core Service -> core Deployment).
        # The selector is the same literal the Deployment is built from, so
        # they cannot drift; the selectorCoherence warning is the price of
        # keeping the workaround visible (BEST-PRACTICES §12.6).
        # root.requires restores the ordering edge to the core Deployment.
        coreService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-core";
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
              # Roll the pods when their configuration changes; a ConfigMap
              # or Secret edit alone does not touch the pod template.
              template.metadata.annotations = {
                "checksum/config" = self.coreConfigMap.out.identityHash;
                "checksum/secret" = self.credentials.out.identityHash;
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "core";
                    image = kix.image.ref config.core.image;
                    imagePullPolicy = config.core.image.pullPolicy;
                    livenessProbe = coreProbe;
                    readinessProbe = coreProbe;
                    startupProbe = coreProbe // {
                      initialDelaySeconds = 10;
                      failureThreshold = 360;
                    };
                    envFrom = [ { configMapRef.name = self.coreConfigMap.out.name; } ];
                    # Secret refs first: Kubernetes only expands $(VAR) from
                    # entries earlier in the list.
                    env =
                      (self.credentials.out.mkEnv {
                        HARBOR_ADMIN_PASSWORD = "adminPassword";
                        CORE_SECRET = "coreSecret";
                        JOBSERVICE_SECRET = "jobserviceSecret";
                        CSRF_KEY = "csrfKey";
                        REGISTRY_CREDENTIAL_PASSWORD = "registryPassword";
                      })
                      ++ (database.out.credentials.out.mkEnv { POSTGRESQL_PASSWORD = "password"; })
                      ++ redisPasswordEnv
                      ++ kix.mkEnvVars {
                        _REDIS_URL_CORE = "${redisUrl 0}?idle_timeout_seconds=30";
                        _REDIS_URL_REG = "${redisUrl 2}?idle_timeout_seconds=30";
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
            (kix.mount.secret self.credentials {
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
            (kix.mount.secret self.credentials {
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
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Portal -- Web UI (nginx)
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
            name = "${name}-portal";
            labels = componentLabels "portal";
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = "http";
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
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Registry -- OCI blob storage, plus the registryctl sidecar
        # ============================================================

        registryConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-registry";
          data = {
            # The redis password arrives as REGISTRY_REDIS_PASSWORD in the
            # container env; distribution overrides config from REGISTRY_*.
            "config.yml" = ''
              version: 0.1
              log:
                level: info
                fields:
                  service: registry
              storage:
                filesystem:
                  rootdirectory: /storage
                cache:
                  layerinfo: redis
                maintenance:
                  uploadpurging:
                    enabled: true
                    age: 168h
                    interval: 24h
                    dryrun: false
                delete:
                  enabled: true
                redirect:
                  disable: false
              redis:
                addr: ${redisAddr}
                db: 2
                readtimeout: 10s
                writetimeout: 10s
                dialtimeout: 10s
                pool:
                  maxidle: 100
                  maxactive: 500
                  idletimeout: 60s
              http:
                addr: :5000
                relativeurls: false
                debug:
                  addr: :${toString metricsPort}
                  prometheus:
                    enabled: ${lib.boolToString metricsEnabled}
                    path: /metrics
              auth:
                htpasswd:
                  realm: harbor-registry-basic-realm
                  path: /etc/registry/passwd
              validation:
                disabled: true
              compatibility:
                schema1:
                  enabled: true
            '';
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
            name = "${name}-registry";
            labels = componentLabels "registry";
            ports = [
              {
                name = "http-registry";
                port = 5000;
                targetPort = "registry";
                protocol = "TCP";
              }
              {
                name = "http-controller";
                port = 8080;
                targetPort = "registryctl";
                protocol = "TCP";
              }
            ]
            ++ metricsServicePort;
            outputs.port = "5000";
          }
          |> scope.mkResource;

        # Shared volumes are injected once, on the registry container;
        # registryctl mounts them by the mount objects' names.
        registryConfigMount = kix.mount.configMap self.registryConfigMap {
          name = "registry-config";
          mountPath = "/etc/registry/config.yml";
          subPath = "config.yml";
        };
        registryDataMount = kix.mount.pvc storage {
          name = "registry-data";
          mountPath = "/storage";
        };

        registryDeployment =
          let
            registryEnv =
              (self.credentials.out.mkEnv { REGISTRY_HTTP_SECRET = "registryHttpSecret"; })
              ++ lib.optionals redisAuth [
                (
                  valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey // { name = "REGISTRY_REDIS_PASSWORD"; }
                )
              ];
          in
          {
            name = "${name}-registry";
            labels = componentSelector "registry";
            spec = {
              replicas = 1;
              revisionHistoryLimit = 5;
              strategy.type = "Recreate";
              selector.matchLabels = componentSelector "registry";
              template.metadata.annotations = {
                "checksum/config" = self.registryConfigMap.out.identityHash;
                "checksum/secret" = self.credentials.out.identityHash;
              };
              template.spec = harborPodDefaults // {
                securityContext = harborPodDefaults.securityContext // {
                  fsGroupChangePolicy = "OnRootMismatch";
                };
                containers = [
                  {
                    name = "registry";
                    image = kix.image.ref config.registry.image;
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
                      ++ (self.credentials.out.mkEnv {
                        CORE_SECRET = "coreSecret";
                        JOBSERVICE_SECRET = "jobserviceSecret";
                      });
                    volumeMounts = [
                      {
                        name = self.registryConfigMount.name;
                        mountPath = "/etc/registry/config.yml";
                        subPath = "config.yml";
                      }
                      {
                        name = self.registryConfigMount.name;
                        mountPath = "/etc/registryctl/config.yml";
                        subPath = "ctl-config.yml";
                      }
                      {
                        name = self.registryDataMount.name;
                        mountPath = "/storage";
                      }
                    ];
                    resources = config.registryctl.resources;
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
          }
          |> kix.withMountsOn "registry" [
            self.registryConfigMount
            (kix.mount.secret self.credentials {
              name = "registry-htpasswd";
              mountPath = "/etc/registry/passwd";
              subPath = "passwd";
              items = [
                {
                  key = "registryHtpasswd";
                  path = "passwd";
                }
              ];
              defaultMode = 420;
            })
            self.registryDataMount
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Jobservice -- Async jobs (replication, GC, scan)
        # ============================================================

        jobserviceConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice";
          data = {
            # redis_url is supplied as JOB_SERVICE_POOL_REDIS_URL in the
            # container env (it carries the password); jobservice overlays
            # JOB_SERVICE_* env on this file.
            "config.yml" = ''
              protocol: "http"
              port: 8080
              worker_pool:
                workers: ${toString config.jobservice.workers}
                backend: "redis"
                redis_pool:
                  namespace: "harbor_job_service_namespace"
                  idle_timeout_second: 3600
              job_loggers:
                - name: "STD_OUTPUT"
                  level: INFO
                - name: "FILE"
                  level: INFO
                  settings:
                    base_dir: "/var/log/jobs"
                  sweeper:
                    duration: 14
                    settings:
                      work_dir: "/var/log/jobs"
              metric:
                enabled: ${lib.boolToString metricsEnabled}
                path: /metrics
                port: ${toString metricsPort}
              loggers:
                - name: "STD_OUTPUT"
                  level: INFO
              reaper:
                max_update_hours: 24
                max_dangling_hours: 168'';
          };
        };

        jobserviceEnvConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice-env";
          data = {
            CORE_URL = coreUrl;
            TOKEN_SERVICE_URL = tokenServiceUrl;
            REGISTRY_URL = registryUrl;
            REGISTRY_CONTROLLER_URL = registryCtlUrl;
            REGISTRY_CREDENTIAL_USERNAME = registryUser;
            JOBSERVICE_WEBHOOK_JOB_MAX_RETRY = "3";
            JOBSERVICE_WEBHOOK_JOB_HTTP_CLIENT_TIMEOUT = "3";
          }
          // lib.optionalAttrs metricsEnabled {
            METRIC_NAMESPACE = "harbor";
            METRIC_SUBSYSTEM = "jobservice";
          };
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
          name = "${name}-jobservice";
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
              strategy.type = "Recreate";
              selector.matchLabels = jobserviceSelector;
              template.metadata.annotations = {
                "checksum/config" = self.jobserviceConfigMap.out.identityHash;
                "checksum/env" = self.jobserviceEnvConfigMap.out.identityHash;
                "checksum/secret" = self.credentials.out.identityHash;
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "jobservice";
                    image = kix.image.ref config.jobservice.image;
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
                    # internalconfig API, but it dials postgres itself, so
                    # the database facts have to appear here for the
                    # netpol egress edge (and they match what core hands
                    # it anyway).
                    env =
                      (self.credentials.out.mkEnv {
                        CORE_SECRET = "coreSecret";
                        JOBSERVICE_SECRET = "jobserviceSecret";
                        REGISTRY_CREDENTIAL_PASSWORD = "registryPassword";
                      })
                      ++ (database.out.credentials.out.mkEnv { POSTGRESQL_PASSWORD = "password"; })
                      ++ redisPasswordEnv
                      ++ kix.mkEnvVars {
                        POSTGRESQL_HOST = database.out.host;
                        POSTGRESQL_PORT = database.out.port;
                        POSTGRESQL_USERNAME = database.out.username;
                        POSTGRESQL_DATABASE = database.out.database;
                        POSTGRESQL_SSLMODE = config.database.sslmode;
                        JOB_SERVICE_POOL_REDIS_URL = redisUrl 1;
                      };
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
            # Job logs also go to stdout; the file logger is a scratch copy
            # the sweeper prunes, so it needs no persistent claim.
            (kix.mount.emptyDir {
              name = "job-logs";
              mountPath = "/var/log/jobs";
            })
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Exporter -- Prometheus metrics exporter (metrics only)
        # ============================================================

        exporterEnvConfigMap =
          if !metricsEnabled then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-exporter-env";
              data = {
                HARBOR_DATABASE_DBNAME = database.out.database;
                HARBOR_DATABASE_HOST = database.out.host;
                HARBOR_DATABASE_PORT = database.out.port;
                HARBOR_DATABASE_USERNAME = database.out.username;
                HARBOR_DATABASE_SSLMODE = config.database.sslmode;
                HARBOR_DATABASE_MAX_IDLE_CONNS = toString config.database.maxIdleConns;
                HARBOR_DATABASE_MAX_OPEN_CONNS = toString config.database.maxOpenConns;
                HARBOR_EXPORTER_CACHE_CLEAN_INTERVAL = "14400";
                HARBOR_EXPORTER_CACHE_TIME = "23";
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
                LOG_LEVEL = "info";
              };
            };

        exporterService =
          if !metricsEnabled then
            null
          else
            self.exporterDeployment
            |> kix.service.fromWorkload {
              name = "${name}-exporter";
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
              spec = {
                replicas = 1;
                revisionHistoryLimit = 5;
                selector.matchLabels = componentSelector "exporter";
                template.metadata.annotations = {
                  "checksum/env" = self.exporterEnvConfigMap.out.identityHash;
                  "checksum/secret" = self.credentials.out.identityHash;
                };
                template.spec = harborPodDefaults // {
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    {
                      name = "exporter";
                      image = kix.image.ref config.exporter.image;
                      imagePullPolicy = config.exporter.image.pullPolicy;
                      args = [
                        "-log-level"
                        "info"
                      ];
                      ports = metricsContainerPort;
                      livenessProbe = exporterProbe // {
                        initialDelaySeconds = 300;
                      };
                      readinessProbe = exporterProbe // {
                        initialDelaySeconds = 30;
                      };
                      envFrom = [ { configMapRef.name = self.exporterEnvConfigMap.out.name; } ];
                      env =
                        (self.credentials.out.mkEnv { HARBOR_ADMIN_PASSWORD = "adminPassword"; })
                        ++ (database.out.credentials.out.mkEnv { HARBOR_DATABASE_PASSWORD = "password"; })
                        ++ redisPasswordEnv
                        ++ kix.mkEnvVars { HARBOR_REDIS_URL = redisUrl 1; };
                      resources = config.exporter.resources;
                      securityContext = containerSecurityContext;
                    }
                  ];
                };
              };
            }
            |> scope.mkDeployment;

        # ============================================================
        # Entry point
        # ============================================================

        # Reachable through the Ingress: the core and portal Services.
        # Neither the core nor the jobservice Service carries a workload
        # edge (see above), so both Deployments are listed here; core's
        # ConfigMap reaches every other component. The exporter and the
        # monitors hang off nothing.
        root = {
          resource = if self.ingress != null then self.ingress else self.coreService;
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

    # Multi-backend ingress: API paths route to core, everything else to
    # the portal. TLS comes from clusterIssuer via kix.expose.
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
      defaultAnnotations = {
        "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
      };
    })

    # One ServiceMonitor per metrics Service. The alert rules ride on the
    # core entry; they cover every component.
    (kix.monitor {
      service = "coreService";
      port = "http-metrics";
      name = "${name}-core";
      monitorPart = "coreMonitor";
      rulesPart = "coreAlerts";
      inherit alerts;
    })
    (kix.monitor {
      service = "registryService";
      port = "http-metrics";
      name = "${name}-registry";
      monitorPart = "registryMonitor";
      rulesPart = "registryAlerts";
    })
    (kix.monitor {
      service = "jobserviceService";
      port = "http-metrics";
      name = "${name}-jobservice";
      monitorPart = "jobserviceMonitor";
      rulesPart = "jobserviceAlerts";
    })
    (kix.monitor {
      service = "exporterService";
      port = "http-metrics";
      name = "${name}-exporter";
      monitorPart = "exporterMonitor";
      rulesPart = "exporterAlerts";
    })
  ];
}
