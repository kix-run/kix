# Harbor container registry kix package.
#
# Multi-component OCI registry: Core (API/auth), Portal (web UI),
# Registry (image storage), Jobservice (async tasks), Redis (cache),
# Exporter (metrics), and Ingress.
#
# Dependencies:
#   postgres       — required, database
#   ingressNginx   — optional, provides IngressClass for ingress
#   clusterIssuer  — optional, provides withCert transformer for TLS
#   prometheus     — optional, gates ServiceMonitor creation and provides CRD ref
#
# Redis is built-in (uses goharbor/redis-photon, Harbor's own image).
#
# Resources per component:
#   Core       -- Deployment, Service, ConfigMap, Secret
#   Portal     -- Deployment, Service, ConfigMap
#   Registry   -- Deployment, Service, ConfigMap, Secret, PVC
#   Jobservice -- Deployment, Service, ConfigMap, Secret, PVC
#   Redis      -- StatefulSet, Service
#   Exporter   -- Deployment, Service, ConfigMap, Secret
#   Ingress    -- Ingress (optional)
#
# root = Ingress (when DI provides ingressNginx + host) or core Service

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
    version = "v2.12.2";
  };

  options = {
    externalURL = lib.mkOption {
      type = lib.types.str;
      default = "https://harbor.example.com";
    };

    core = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "goharbor/harbor-core";
          tag = "v2.12.2";
        };
      };
      replicas = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
    };

    portal = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "goharbor/harbor-portal";
          tag = "v2.12.2";
        };
      };
      replicas = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
    };

    registry = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "goharbor/harbor-registryctl";
          tag = "v2.12.2";
        };
      };
      replicas = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
    };

    jobservice = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "goharbor/harbor-jobservice";
          tag = "v2.12.2";
        };
      };
      replicas = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
    };

    trivy = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };

    metrics = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 8001;
      };
    };

    persistence = {
      registry = lib.mkOption {
        type = lib.types.anything;
        default = {
          size = "200Gi";
          storageClass = null;
        };
      };
      jobservice = lib.mkOption {
        type = lib.types.anything;
        default = {
          size = "1Gi";
          storageClass = null;
        };
      };
    };

    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        host = null;
        annotations = { };
      };
    };

    database = lib.mkOption {
      type = lib.types.anything;
      default = {
        username = "harbor";
        host = null;
        existingSecret = null;
        sslmode = "require";
        maxIdleConns = "100";
        maxOpenConns = "900";
      };
    };

    redis = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "goharbor/redis-photon";
          tag = "v2.12.2";
        };
        persistence = {
          size = "2Gi";
          storageClass = null;
        };
        resources = {
          requests = {
            cpu = "20m";
            memory = "64Mi";
          };
          limits = {
            cpu = "1";
            memory = "1Gi";
          };
        };
      };
    };

    secretKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    adminPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        postgres,
        prometheus ? null,
      }:
      let
        # --- Derived values ---

        hasMetrics = config.metrics.enabled && prometheus != null;

        redisHost = "${name}-redis";
        redisPort = "6379";
        dbHost = if config.database.host != null then config.database.host else postgres.out.fqdn;
        noProxy = "${name}-core,${name}-jobservice,${name}-database,${name}-registry,${name}-portal,${name}-trivy,${name}-exporter,127.0.0.1,localhost,.local,.internal";

        # Internal URLs — plain strings matching the service names.
        # No self-reference needed: these are deterministic from the instance name.
        coreInternalURL = "http://${name}-core:80";
        registryInternalURL = "http://${name}-registry:5000";
        registryCtlInternalURL = "http://${name}-registry:8080";
        portalInternalURL = "http://${name}-portal";
        jobserviceInternalURL = "http://${name}-jobservice";
        tokenServiceURL = "${coreInternalURL}/service/token";

        # --- Shared let bindings ---

        selectorLabels = {
          app = "harbor";
          release = name;
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

        # Per-component probes — base holds shared thresholds,
        # each component overrides httpGet. Sites add initialDelaySeconds via //.
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

        # ServiceMonitor builder from prometheus DI dep
        mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

      in
      {

        # ============================================================
        # TLS secret reference
        # ============================================================
        #
        # Harbor's core uses the cert-manager-issued ingress TLS cert as the
        # JWT signing key for the registry token service. The Secret is created
        # by cert-manager (triggered by `clusterIssuer.out.withCert` on the
        # Ingress, wired via `kix.expose` below), so kix doesn't manage it
        # directly — but `mkSecretRef` makes the reference DI-tracked and gates
        # consumers (the core Deployment volume mount) on the Secret existing.
        tlsSecret = scope.mkSecretRef {
          name = "${name}-ingress";
          keys = [ "tls.key" ];
        };

        # ============================================================
        # Core -- API server, auth, project management
        # ============================================================

        coreConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-core";
          data = {
            EXT_ENDPOINT = config.externalURL;
            CONFIG_PATH = "/etc/core/app.conf";
            CORE_URL = coreInternalURL;
            CORE_LOCAL_URL = "http://127.0.0.1:8080";
            JOBSERVICE_URL = jobserviceInternalURL;
            REGISTRY_URL = registryInternalURL;
            REGISTRY_CONTROLLER_URL = registryCtlInternalURL;
            TOKEN_SERVICE_URL = tokenServiceURL;
            PORTAL_URL = portalInternalURL;
            TRIVY_ADAPTER_URL = "http://${name}-trivy:8080";
            REGISTRY_STORAGE_PROVIDER_NAME = "filesystem";
            WITH_TRIVY = if config.trivy.enabled then "true" else "false";
            REGISTRY_CREDENTIAL_USERNAME = "harbor_registry_user";
            PORT = "8080";
            QUOTA_UPDATE_PROVIDER = "db";
            DATABASE_TYPE = "postgresql";
            POSTGRESQL_HOST = dbHost;
            POSTGRESQL_PORT = postgres.out.port;
            POSTGRESQL_USERNAME = config.database.username;
            POSTGRESQL_SSLMODE = config.database.sslmode;
            POSTGRESQL_DATABASE = "registry";
            POSTGRESQL_MAX_IDLE_CONNS = config.database.maxIdleConns;
            POSTGRESQL_MAX_OPEN_CONNS = config.database.maxOpenConns;
            _REDIS_URL_CORE = "redis://${redisHost}:${redisPort}/0?idle_timeout_seconds=30";
            _REDIS_URL_REG = "redis://${redisHost}:${redisPort}/2?idle_timeout_seconds=30";
            PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE = "docker-hub,harbor,azure-acr,aws-ecr,google-gcr,quay,docker-registry,github-ghcr,jfrog-artifactory";
            LOG_LEVEL = "info";
            HTTP_PROXY = "";
            HTTPS_PROXY = "";
            NO_PROXY = noProxy;
            CHART_CACHE_DRIVER = "redis";
            "app.conf" = ''
              appname = Harbor
              runmode = prod
              enablegzip = true
              [prod]
              httpport = 8080'';
          }
          // lib.optionalAttrs config.metrics.enabled {
            METRIC_ENABLE = "true";
            METRIC_NAMESPACE = "harbor";
            METRIC_PATH = "/metrics";
            METRIC_PORT = toString config.metrics.port;
            METRIC_SUBSYSTEM = "core";
          };
        };

        coreSecret = scope.mkSecret {
          name = "${name}-core";
          stringData = {
            HARBOR_ADMIN_PASSWORD =
              if config.adminPassword != null then config.adminPassword else "Harbor12345";
            secretKey = if config.secretKey != null then config.secretKey else "not-a-secure-key!";
            secret = "not-a-secure-key!";
            CSRF_KEY = "not-a-secure-csrf-key-change-me!";
            REGISTRY_CREDENTIAL_PASSWORD = "harbor_registry_password";
          }
          // lib.optionalAttrs (config.database.existingSecret == null) {
            POSTGRESQL_PASSWORD = "";
          };
        };

        coreService =
          self.coreDeployment
          |> kix.service.fromWorkload {
            name = "${name}-core";
            ports = [
              {
                name = "http-web";
                port = 80;
                targetPort = 8080;
                protocol = "TCP";
              }
            ]
            ++ lib.optionals config.metrics.enabled [
              {
                name = "http-metrics";
                port = config.metrics.port;
                targetPort = config.metrics.port;
                protocol = "TCP";
              }
            ];
            outputs.port = "80";
          }
          |> scope.mkResource;

        # --- Core mounts ---
        coreConfigMount = kix.mount.configMap self.coreConfigMap {
          name = "config";
          mountPath = "/etc/core/app.conf";
          subPath = "app.conf";
          items = [
            {
              key = "app.conf";
              path = "app.conf";
            }
          ];
        };
        coreSecretKeyMount = kix.mount.secret self.coreSecret {
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
        };

        coreDeployment =
          {
            name = "${name}-core";
            spec = {
              replicas = config.core.replicas;
              revisionHistoryLimit = 5;
              selector.matchLabels = selectorLabels // {
                component = "core";
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "core";
                    image = "${config.core.image.repository}:${config.core.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    livenessProbe = coreProbe;
                    readinessProbe = coreProbe;
                    startupProbe = coreProbe // {
                      initialDelaySeconds = 10;
                      failureThreshold = 360;
                    };
                    envFrom = [
                      { configMapRef.name = self.coreConfigMap.out.name; }
                      self.coreSecret.out.envFrom
                    ];
                    env = [
                      (self.coreSecret.out.keyRef "secret" // { name = "CORE_SECRET"; })
                      (self.jobserviceSecret.out.keyRef "JOBSERVICE_SECRET" // { name = "JOBSERVICE_SECRET"; })
                    ];
                    ports = [
                      {
                        containerPort = 8080;
                        protocol = "TCP";
                      }
                    ];
                    resources = {
                      requests = {
                        cpu = "20m";
                        memory = "128Mi";
                      };
                      limits = {
                        cpu = "1";
                        memory = "256Mi";
                      };
                    };
                    securityContext = containerSecurityContext;
                    volumeMounts = [
                      {
                        name = "token-service-private-key";
                        mountPath = "/etc/core/private_key.pem";
                        subPath = "tls.key";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "token-service-private-key";
                    secret = {
                      secretName = self.tlsSecret.out.name;
                      defaultMode = 420;
                    };
                  }
                ];
              };
            };
          }
          |> kix.withMounts [
            self.coreConfigMount
            (kix.mount.emptyDir {
              name = "ca-download";
              mountPath = "/etc/core/ca";
            })
            self.coreSecretKeyMount
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
            ports = [
              {
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
            spec = {
              replicas = config.portal.replicas;
              revisionHistoryLimit = 5;
              selector.matchLabels = selectorLabels // {
                component = "portal";
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "portal";
                    image = "${config.portal.image.repository}:${config.portal.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    ports = [
                      {
                        containerPort = 8080;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = portalProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = portalProbe // {
                      initialDelaySeconds = 1;
                    };
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
        # Registry -- OCI image storage
        # ============================================================

        registryPVC = scope.mkResource {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          name = "${name}-registry";
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = config.persistence.registry.size;
          }
          // lib.optionalAttrs (config.persistence.registry.storageClass != null) {
            storageClassName = config.persistence.registry.storageClass;
          };
        };

        registryConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-registry";
          data = {
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
                addr: ${redisHost}:${redisPort}
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
                # set via environment variable
                # secret: placeholder
                debug:
                  addr: :${toString config.metrics.port}
                  prometheus:
                    enabled: true
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

        registrySecret = scope.mkSecret {
          name = "${name}-registry";
          stringData = {
            REGISTRY_HTTP_SECRET = "placeholder-http-secret";
            REGISTRY_HTPASSWD = "harbor_registry_user:$2y$10$placeholder_bcrypt_hash";
          };
        };

        registryHtpasswdSecret = scope.mkSecret {
          name = "${name}-registry-htpasswd";
          stringData = {
            REGISTRY_HTPASSWD = "harbor_registry_user:$2y$10$placeholder_bcrypt_hash";
          };
        };

        registryService =
          self.registryDeployment
          |> kix.service.fromWorkload {
            name = "${name}-registry";
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
            ++ lib.optionals config.metrics.enabled [
              {
                name = "http-metrics";
                port = config.metrics.port;
                targetPort = config.metrics.port;
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        # Registry has 2 containers sharing volumes — manual volumeMounts,
        # but kix.withMounts for the shared volume list via targetContainer.
        registryDeployment =
          {
            name = "${name}-registry";
            spec = {
              replicas = config.registry.replicas;
              revisionHistoryLimit = 5;
              strategy.type = "Recreate";
              selector.matchLabels = selectorLabels // {
                component = "registry";
              };
              template.spec = harborPodDefaults // {
                securityContext = harborPodDefaults.securityContext // {
                  fsGroupChangePolicy = "OnRootMismatch";
                };
                containers = [
                  {
                    name = "registry";
                    image = "goharbor/registry-photon:${config.registry.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    ports = [
                      {
                        containerPort = 5000;
                        protocol = "TCP";
                      }
                      {
                        containerPort = config.metrics.port;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = registryProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = registryProbe // {
                      initialDelaySeconds = 1;
                    };
                    envFrom = [ self.registrySecret.out.envFrom ];
                    volumeMounts = [
                      {
                        name = "registry-config";
                        mountPath = "/etc/registry/config.yml";
                        subPath = "config.yml";
                      }
                      {
                        name = "registry-htpasswd";
                        mountPath = "/etc/registry/passwd";
                        subPath = "passwd";
                      }
                      {
                        name = "registry-data";
                        mountPath = "/storage";
                      }
                    ];
                    securityContext = containerSecurityContext;
                  }
                  {
                    name = "registryctl";
                    image = "${config.registry.image.repository}:${config.registry.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    ports = [
                      {
                        containerPort = 8080;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = registryCtlProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = registryCtlProbe // {
                      initialDelaySeconds = 1;
                    };
                    env = [
                      (self.coreSecret.out.keyRef "secret" // { name = "CORE_SECRET"; })
                      (self.jobserviceSecret.out.keyRef "JOBSERVICE_SECRET" // { name = "JOBSERVICE_SECRET"; })
                    ];
                    envFrom = [
                      { configMapRef.name = self.registryCtlConfigMap.out.name; }
                      self.registrySecret.out.envFrom
                      self.registryCtlSecret.out.envFrom
                    ];
                    volumeMounts = [
                      {
                        name = "registry-config";
                        mountPath = "/etc/registry/config.yml";
                        subPath = "config.yml";
                      }
                      {
                        name = "registry-config";
                        mountPath = "/etc/registryctl/config.yml";
                        subPath = "ctl-config.yml";
                      }
                      {
                        name = "registry-data";
                        mountPath = "/storage";
                      }
                    ];
                    securityContext = containerSecurityContext;
                  }
                ];
                volumes = [
                  {
                    name = "registry-config";
                    configMap.name = self.registryConfigMap.out.name;
                  }
                  {
                    name = "registry-data";
                    persistentVolumeClaim.claimName = self.registryPVC.out.name;
                  }
                  {
                    name = "registry-htpasswd";
                    secret = {
                      secretName = self.registryHtpasswdSecret.out.name;
                      defaultMode = 420;
                      items = [
                        {
                          key = "REGISTRY_HTPASSWD";
                          path = "passwd";
                        }
                      ];
                    };
                  }
                ];
              };
            };
          }
          |> scope.mkDeployment;

        registryCtlConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-registryctl";
        };

        registryCtlSecret = scope.mkSecret {
          name = "${name}-registryctl";
          keys = [ ];
          stringData = { };
        };

        # ============================================================
        # Jobservice -- Async jobs (replication, GC, scan)
        # ============================================================

        jobserviceConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice";
          data = {
            "config.yml" = ''
              #Server listening port
              protocol: "http"
              port: 8080
              worker_pool:
                workers: 10
                backend: "redis"
                redis_pool:
                  redis_url: "redis://${redisHost}:${redisPort}/1"
                  namespace: "harbor_job_service_namespace"
                  idle_timeout_second: 3600
              job_loggers:
                - name: "FILE"
                  level: INFO
                  settings: # Customized settings of logger
                    base_dir: "/var/log/jobs"
                  sweeper:
                    duration: 14 #days
                    settings: # Customized settings of sweeper
                      work_dir: "/var/log/jobs"
              metric:
                enabled: true
                path: /metrics
                port: ${toString config.metrics.port}
              #Loggers for the job service
              loggers:
                - name: "STD_OUTPUT"
                  level: INFO
              reaper:
                # the max time to wait for a task to finish, if unfinished after max_update_hours, the task will be mark as error, but the task will continue to run, default value is 24
                max_update_hours: 24
                # the max time for execution in running state without new task created
                max_dangling_hours: 168'';
          };
        };

        jobserviceEnvConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-jobservice-env";
          data = {
            CORE_URL = coreInternalURL;
            TOKEN_SERVICE_URL = tokenServiceURL;
            REGISTRY_URL = registryInternalURL;
            REGISTRY_CONTROLLER_URL = registryCtlInternalURL;
            REGISTRY_CREDENTIAL_USERNAME = "harbor_registry_user";
            HTTP_PROXY = "";
            HTTPS_PROXY = "";
            NO_PROXY = noProxy;
            JOBSERVICE_WEBHOOK_JOB_MAX_RETRY = "3";
            JOBSERVICE_WEBHOOK_JOB_HTTP_CLIENT_TIMEOUT = "3";
          }
          // lib.optionalAttrs config.metrics.enabled {
            METRIC_NAMESPACE = "harbor";
            METRIC_SUBSYSTEM = "jobservice";
          };
        };

        jobserviceSecret = scope.mkSecret {
          name = "${name}-jobservice";
          stringData = {
            CORE_SECRET = "not-a-secure-secret";
            JOBSERVICE_SECRET = "not-a-secure-secret";
            REGISTRY_CREDENTIAL_PASSWORD = "harbor_registry_password";
          };
        };

        jobserviceService =
          self.jobserviceDeployment
          |> kix.service.fromWorkload {
            name = "${name}-jobservice";
            ports = [
              {
                name = "http-jobservice";
                port = 80;
                targetPort = 8080;
                protocol = "TCP";
              }
            ]
            ++ lib.optionals config.metrics.enabled [
              {
                name = "http-metrics";
                port = config.metrics.port;
                targetPort = config.metrics.port;
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        jobservicePVC = scope.mkResource {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          name = "${name}-jobservice";
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = config.persistence.jobservice.size;
          }
          // lib.optionalAttrs (config.persistence.jobservice.storageClass != null) {
            storageClassName = config.persistence.jobservice.storageClass;
          };
        };

        jobserviceDeployment =
          {
            name = "${name}-jobservice";
            spec = {
              replicas = config.jobservice.replicas;
              revisionHistoryLimit = 5;
              strategy.type = "Recreate";
              selector.matchLabels = selectorLabels // {
                component = "jobservice";
              };
              template.spec = harborPodDefaults // {
                containers = [
                  {
                    name = "jobservice";
                    image = "${config.jobservice.image.repository}:${config.jobservice.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    ports = [
                      {
                        containerPort = 8080;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = jobserviceProbe // {
                      initialDelaySeconds = 300;
                    };
                    readinessProbe = jobserviceProbe // {
                      initialDelaySeconds = 20;
                    };
                    env = [
                      (self.coreSecret.out.keyRef "secret" // { name = "CORE_SECRET"; })
                    ];
                    envFrom = [
                      { configMapRef.name = self.jobserviceEnvConfigMap.out.name; }
                      self.jobserviceSecret.out.envFrom
                    ];
                    resources = {
                      requests = {
                        cpu = "20m";
                        memory = "128Mi";
                      };
                      limits = {
                        cpu = "2";
                        memory = "1Gi";
                      };
                    };
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
            (kix.mount.pvc self.jobservicePVC {
              name = "job-logs";
              mountPath = "/var/log/jobs";
            })
          ]
          |> scope.mkDeployment;

        # ============================================================
        # Exporter -- Prometheus metrics exporter
        # ============================================================

        exporterSecret = scope.mkSecret {
          name = "${name}-exporter";
          keys = [ ];
          stringData = { };
        };

        exporterEnvConfigMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-exporter-env";
          data = {
            HARBOR_DATABASE_DBNAME = "registry";
            HARBOR_DATABASE_HOST = dbHost;
            HARBOR_DATABASE_MAX_IDLE_CONNS = config.database.maxIdleConns;
            HARBOR_DATABASE_MAX_OPEN_CONNS = config.database.maxOpenConns;
            HARBOR_DATABASE_PORT = toString postgres.out.port;
            HARBOR_DATABASE_SSLMODE = config.database.sslmode;
            HARBOR_DATABASE_USERNAME = config.database.username;
            HARBOR_EXPORTER_CACHE_CLEAN_INTERVAL = "14400";
            HARBOR_EXPORTER_CACHE_TIME = "23";
            HARBOR_EXPORTER_METRICS_ENABLED = "true";
            HARBOR_EXPORTER_METRICS_PATH = "/metrics";
            HARBOR_EXPORTER_PORT = toString config.metrics.port;
            HARBOR_METRIC_NAMESPACE = "harbor";
            HARBOR_METRIC_SUBSYSTEM = "exporter";
            HARBOR_REDIS_NAMESPACE = "harbor_job_service_namespace";
            HARBOR_REDIS_TIMEOUT = "3600";
            HARBOR_REDIS_URL = "redis://${redisHost}:${redisPort}/1";
            HARBOR_SERVICE_HOST = "${name}-core";
            HARBOR_SERVICE_PORT = "80";
            HARBOR_SERVICE_SCHEME = "http";
            HTTP_PROXY = "";
            HTTPS_PROXY = "";
            LOG_LEVEL = "info";
            NO_PROXY = noProxy;
          };
        };

        exporterService =
          self.exporterDeployment
          |> kix.service.fromWorkload {
            name = "${name}-exporter";
            ports = [
              {
                name = "http-metrics";
                port = config.metrics.port;
                targetPort = config.metrics.port;
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        exporterDeployment =
          {
            name = "${name}-exporter";
            spec = {
              replicas = 1;
              revisionHistoryLimit = 5;
              selector.matchLabels = selectorLabels // {
                component = "exporter";
              };
              template.spec = {
                automountServiceAccountToken = false;
                terminationGracePeriodSeconds = 30;
                securityContext = {
                  runAsUser = 10000;
                  fsGroup = 10000;
                };
                containers = [
                  {
                    name = "exporter";
                    image = "goharbor/harbor-exporter:${config.core.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    args = [
                      "-log-level"
                      "info"
                    ];
                    ports = [
                      {
                        containerPort = config.metrics.port;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe = {
                      httpGet = {
                        path = "/";
                        port = config.metrics.port;
                        scheme = "HTTP";
                      };
                      initialDelaySeconds = 300;
                      periodSeconds = 10;
                      failureThreshold = 3;
                      timeoutSeconds = 1;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/";
                        port = config.metrics.port;
                        scheme = "HTTP";
                      };
                      initialDelaySeconds = 30;
                      periodSeconds = 10;
                      failureThreshold = 3;
                      timeoutSeconds = 1;
                    };
                    envFrom = [
                      { configMapRef.name = self.exporterEnvConfigMap.out.name; }
                      self.exporterSecret.out.envFrom
                    ];
                    securityContext = containerSecurityContext;
                  }
                ];
                volumes = [
                  {
                    name = "config";
                    secret = {
                      secretName = self.exporterSecret.out.name;
                      defaultMode = 420;
                    };
                  }
                ];
              };
            };
          }
          |> scope.mkDeployment;

        # ============================================================
        # ServiceMonitor -- Prometheus scrape config
        # ============================================================

        serviceMonitor =
          if hasMetrics then
            mkServiceMonitor {
              name = name;
              spec = {
                endpoints = [
                  {
                    honorLabels = true;
                    port = "http-metrics";
                  }
                ];
                jobLabel = "app.kubernetes.io/name";
                selector.matchLabels = selectorLabels;
              };
            }
          else
            null;

        # ============================================================
        # PrometheusRule -- Alert definitions
        # ============================================================

        prometheusRules =
          if hasMetrics then
            prometheus.out.mkPrometheusRule scope {
              name = "${name}-alerts";
              spec = {
                groups = [
                  {
                    name = "harbor-alerts";
                    rules = [
                      {
                        alert = "HarborHealthCheckFailed";
                        expr = "harbor_health == 0";
                        "for" = "5m";
                        labels.severity = "critical";
                        annotations = {
                          summary = "Harbor health check failed";
                          description = "Harbor instance {{ $labels.instance }} health check is failing.";
                        };
                      }
                      {
                        alert = "HarborCoreHighInflightRequests";
                        expr = "harbor_core_http_inflight_requests > 100";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High number of inflight requests in Harbor Core";
                          description = "Harbor Core instance {{ $labels.instance }} has more than 100 inflight requests.";
                        };
                      }
                      {
                        alert = "HarborCoreHighRequestDuration";
                        expr = "(sum by (method, instance) (rate(harbor_core_http_request_duration_seconds_sum[1m]) ) / sum by (method, instance) (rate(harbor_core_http_request_duration_seconds_count[1m]) )) > 1";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High request duration in Harbor Core";
                          description = "Harbor Core instance {{ $labels.instance }} has an average {{ $labels.method }} request duration of more than 1 second.";
                        };
                      }
                      {
                        alert = "HarborCoreHttp5xxRequestErrors";
                        expr = ''sum(rate(harbor_core_http_request_total{code=~"5.."}[5m])) / sum(rate(harbor_core_http_request_total[5m])) > 0.1'';
                        "for" = "10m";
                        labels.severity = "critical";
                        annotations = {
                          summary = "High rate of HTTP 5xx errors in Harbor Core";
                          description = "Harbor Core instance {{ $labels.instance }} is experiencing more than 10% HTTP 5xx errors";
                        };
                      }
                      {
                        alert = "HarborCoreHttp4xxRequestErrors";
                        expr = ''sum(rate(harbor_core_http_request_total{code=~"4.."}[5m])) / sum(rate(harbor_core_http_request_total[5m])) > 0.3'';
                        "for" = "10m";
                        labels.severity = "critical";
                        annotations = {
                          summary = "High rate of HTTP 4xx errors in Harbor Core";
                          description = "Harbor Core instance {{ $labels.instance }} is experiencing more than 30% HTTP 4xx errors";
                        };
                      }
                      {
                        alert = "HarborArtifactPullsHigh";
                        expr = "rate(harbor_artifact_pulled[5m]) > 0.1";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High rate of artifact pulls in Harbor";
                          description = "Harbor instance {{ $labels.instance }} is experiencing a high rate of artifact pulls.";
                        };
                      }
                      {
                        alert = "HarborProjectQuotaUsageHigh";
                        expr = "(harbor_project_quota_usage_byte / harbor_project_quota_byte) > 0.8";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High quota usage in Harbor project";
                          description = "Quota usage in Harbor project {{ $labels.project_name }} is above 80%.";
                        };
                      }
                      {
                        alert = "HarborTaskQueueSizeHigh";
                        expr = "harbor_task_queue_size > 20";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High task queue size in Harbor";
                          description = "Harbor instance {{ $labels.instance }} has more than 20 tasks in the queue.";
                        };
                      }
                      {
                        alert = "HarborTaskQueueLatencyHigh";
                        expr = "harbor_task_queue_latency > 60";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High task queue latency in Harbor";
                          description = "Harbor instance {{ $labels.instance }} has a task queue latency of more than 60 seconds.";
                        };
                      }
                      {
                        alert = "HarborTaskConcurrencyHigh";
                        expr = "harbor_task_concurrency > 10";
                        "for" = "10m";
                        labels.severity = "warning";
                        annotations = {
                          summary = "High task concurrency in Harbor";
                          description = "Harbor instance {{ $labels.instance }} is running more than 10 tasks concurrently.";
                        };
                      }
                      {
                        alert = "HarborInstanceDown";
                        expr = ''up{job="harbor"} == 0'';
                        "for" = "5m";
                        labels.severity = "critical";
                        annotations = {
                          summary = "Harbor instance is down";
                          description = "Harbor instance {{ $labels.instance }} is down.";
                        };
                      }
                    ];
                  }
                ];
              };
            }
          else
            null;

        # ============================================================
        # Ingress — wired by the kix.expose build entry below.
        # ============================================================

        # ============================================================
        # Redis (built-in, part of Harbor)
        # ============================================================

        redisStatefulSet =
          {
            name = "${name}-redis";
            labels = selectorLabels // {
              component = "redis";
            };
            spec = {
              serviceName = self.redisService.name;
              replicas = 1;
              podManagementPolicy = "OrderedReady";
              selector.matchLabels = selectorLabels // {
                component = "redis";
              };
              template.spec = {
                securityContext = {
                  runAsUser = 999;
                  fsGroup = 999;
                };
                automountServiceAccountToken = false;
                terminationGracePeriodSeconds = 120;
                containers = [
                  {
                    name = "redis";
                    image = "${config.redis.image.repository}:${config.redis.image.tag}";
                    imagePullPolicy = "IfNotPresent";
                    livenessProbe = {
                      tcpSocket.port = 6379;
                      initialDelaySeconds = 300;
                      periodSeconds = 10;
                      timeoutSeconds = 1;
                      failureThreshold = 3;
                      successThreshold = 1;
                    };
                    readinessProbe = {
                      tcpSocket.port = 6379;
                      initialDelaySeconds = 1;
                      periodSeconds = 10;
                      timeoutSeconds = 1;
                      failureThreshold = 3;
                      successThreshold = 1;
                    };
                    resources = config.redis.resources;
                    securityContext = containerSecurityContext;
                    volumeMounts = [
                      {
                        name = "data";
                        mountPath = "/var/lib/redis";
                      }
                    ];
                  }
                ];
              };
              volumeClaimTemplates = [
                {
                  metadata = {
                    name = "data";
                    labels = selectorLabels;
                  };
                  spec = {
                    accessModes = [ "ReadWriteOnce" ];
                    resources.requests.storage = config.redis.persistence.size;
                  }
                  // lib.optionalAttrs (config.redis.persistence.storageClass != null) {
                    storageClassName = config.redis.persistence.storageClass;
                  };
                }
              ];
            };
          }
          |> scope.mkStatefulSet;

        redisService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-redis";
          labels = selectorLabels // {
            component = "redis";
          };
          spec = {
            clusterIP = "None";
            selector = selectorLabels // {
              component = "redis";
            };
            ports = [
              {
                port = 6379;
                targetPort = 6379;
                protocol = "TCP";
              }
            ];
          };
          outputs = {
            port = "6379";
          };
          requires = [ self.redisStatefulSet ];
        };

        # ============================================================
        # Entry point
        # ============================================================

        root = {
          resource = if self.ingress != null then self.ingress else self.coreService;
          requires = [
            self.coreDeployment
            self.coreService
            self.portalDeployment
            self.portalService
            self.registryDeployment
            self.registryService
            self.registryHtpasswdSecret
            self.registryCtlConfigMap
            self.registryCtlSecret
            self.jobserviceDeployment
            self.jobserviceService
            self.jobserviceEnvConfigMap
            self.jobservicePVC
            self.exporterSecret
            self.exporterEnvConfigMap
            self.exporterDeployment
            self.exporterService
            self.redisStatefulSet
            self.redisService
          ]
          ++ lib.optional (self.ingress != null) self.ingress
          ++ lib.optional hasMetrics self.serviceMonitor
          ++ lib.optional hasMetrics self.prometheusRules;
        };
      }
    )

    # Multi-backend ingress: 4 paths route to coreService, '/' routes to portalService.
    # Uses `self.tlsSecret` (a mkSecretRef marker) so cert-manager's Secret is
    # DI-tracked, gating the core Deployment's volume mount on its existence.
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
        "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
      };
      tlsSecretPart = "tlsSecret";
    })
  ];
}
