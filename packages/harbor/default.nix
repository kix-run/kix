# Harbor container registry kix package.
#
# Multi-component OCI registry: Core (API/auth), Portal (web UI),
# Registry (image storage), Jobservice (async tasks),
# Redis (internal cache), and Ingress.
#
# Resources per component:
#   Core       -- Deployment, Service, ConfigMap, Secret
#   Portal     -- Deployment, Service, ConfigMap
#   Registry   -- Deployment, Service, ConfigMap, Secret, PVC
#   Jobservice -- Deployment, Service, ConfigMap, Secret
#   Redis      -- StatefulSet, Service, PVC (when type=internal)
#   Ingress    -- Ingress
#
# main = Ingress (or core Service when ingress disabled)

{
  scope,
  lib,
  postgres,
}:

{
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

    redis = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = {
          repository = "goharbor/redis-photon";
          tag = "v2.12.2";
        };
      };
      type = lib.mkOption {
        type = lib.types.str;
        default = "internal";
      };
      external = lib.mkOption {
        type = lib.types.anything;
        default = {
          host = "";
          port = "6379";
        };
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
      redis = lib.mkOption {
        type = lib.types.anything;
        default = {
          size = "2Gi";
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
        enabled = true;
        className = "public-v2";
        hosts = {
          core = "harbor.example.com";
        };
        tls = {
          enabled = true;
          secretName = "harbor-ingress";
        };
      };
    };

    database = lib.mkOption {
      type = lib.types.anything;
      default = {
        username = "harbor";
        host = null; # if set, overrides postgres.out.fqdn for POSTGRESQL_HOST
        existingSecret = null;
        sslmode = "require";
        maxIdleConns = "100";
        maxOpenConns = "900";
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

  build = { self, config, clusterConfig }:
  let
    name = scope.instanceName;
    ns = scope.namespaceName;

    # --- Derived values ---

    useInternalRedis = config.redis.type == "internal";

    redisHost =
      if useInternalRedis then "${name}-redis" else config.redis.external.host;
    redisPort = if useInternalRedis then "6379" else config.redis.external.port;

    coreServicePort = 80;
    portalServicePort = 80;
    jobserviceServicePort = 80;

    coreInternalURL = "http://${name}-core:${toString coreServicePort}";
    registryInternalURL = "http://${name}-registry:5000";
    registryCtlInternalURL = "http://${name}-registry:8080";
    portalInternalURL = "http://${name}-portal";
    jobserviceInternalURL = "http://${name}-jobservice";
    tokenServiceURL = "${coreInternalURL}/service/token";

    # Common labels for all resources (metadata labels include both styles).
    commonLabels = {
      "app.kubernetes.io/name" = "harbor";
      "app.kubernetes.io/instance" = name;
    };

    # Helm-style selector labels used by selectors/matchLabels.
    helmSelectorLabels = {
      app = "harbor";
      release = name;
    };

    # Per-component selector labels (Helm-style for selectors).
    componentSelectorLabels = component:
      helmSelectorLabels // {
        inherit component;
      };

    # Per-component metadata labels (both styles).
    componentLabels = component:
      commonLabels // {
        "app.kubernetes.io/component" = component;
      };

    # Per-container security context matching the Helm chart pattern.
    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      privileged = false;
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };

    noProxy = "${name}-core,${name}-jobservice,${name}-database,${name}-registry,${name}-portal,${name}-trivy,${name}-exporter,127.0.0.1,localhost,.local,.internal";

  in
  {

    # ============================================================
    # Core -- API server, auth, project management
    # ============================================================

    coreConfigMap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-core";
      labels = componentLabels "core";
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

        # Database
        DATABASE_TYPE = "postgresql";
        POSTGRESQL_HOST = if config.database.host != null then config.database.host else postgres.out.fqdn;
        POSTGRESQL_PORT = postgres.out.port;
        POSTGRESQL_USERNAME = config.database.username;
        POSTGRESQL_SSLMODE = config.database.sslmode;
        POSTGRESQL_DATABASE = "registry";
        POSTGRESQL_MAX_IDLE_CONNS = config.database.maxIdleConns;
        POSTGRESQL_MAX_OPEN_CONNS = config.database.maxOpenConns;

        # Redis
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

    coreSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-core";
      labels = componentLabels "core";
      extra = {
        type = "Opaque";
        stringData = {
          HARBOR_ADMIN_PASSWORD = if config.adminPassword != null then config.adminPassword else "Harbor12345";
          secretKey = if config.secretKey != null then config.secretKey else "not-a-secure-key!";
          secret = "not-a-secure-key!";
          CSRF_KEY = "not-a-secure-csrf-key-change-me!";
          REGISTRY_CREDENTIAL_PASSWORD = "harbor_registry_password";
        }
        // lib.optionalAttrs (config.database.existingSecret == null) {
          POSTGRESQL_PASSWORD = "";
        };
      };
    };

    coreService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-core";
      labels = componentLabels "core";
      spec = {
        type = "ClusterIP";
        selector = componentSelectorLabels "core";
        ports = [
          {
            name = "http-web";
            port = coreServicePort;
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
      };
    };

    coreDeployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-core";
      labels = componentLabels "core";
      spec = {
        replicas = config.core.replicas;
        revisionHistoryLimit = 5;
        selector.matchLabels = componentSelectorLabels "core";
        template = {
          metadata.labels = componentLabels "core";
          spec = {
            securityContext = {
              runAsUser = 10000;
              fsGroup = 10000;
            };
            automountServiceAccountToken = false;
            terminationGracePeriodSeconds = 120;
            containers = [
              {
                name = "core";
                image = "${config.core.image.repository}:${config.core.image.tag}";
                imagePullPolicy = "IfNotPresent";
                livenessProbe = {
                  httpGet = {
                    path = "/api/v2.0/ping";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  periodSeconds = 10;
                  failureThreshold = 2;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/v2.0/ping";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  periodSeconds = 10;
                  failureThreshold = 2;
                };
                startupProbe = {
                  httpGet = {
                    path = "/api/v2.0/ping";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 360;
                };
                envFrom = [
                  { configMapRef.name = self.coreConfigMap.out.name; }
                  { secretRef.name = self.coreSecret.out.name; }
                ];
                env = [
                  {
                    name = "CORE_SECRET";
                    valueFrom.secretKeyRef = {
                      name = self.coreSecret.out.name;
                      key = "secret";
                    };
                  }
                  {
                    name = "JOBSERVICE_SECRET";
                    valueFrom.secretKeyRef = {
                      name = self.jobserviceSecret.out.name;
                      key = "JOBSERVICE_SECRET";
                    };
                  }
                ]
                ++ lib.optionals (config.database.existingSecret != null) [
                  {
                    name = "POSTGRESQL_PASSWORD";
                    valueFrom.secretKeyRef = {
                      name = config.database.existingSecret;
                      key = "password";
                    };
                  }
                ];
                ports = [
                  {
                    containerPort = 8080;
                    protocol = "TCP";
                  }
                ];
                volumeMounts = [
                  {
                    name = "config";
                    mountPath = "/etc/core/app.conf";
                    subPath = "app.conf";
                  }
                  {
                    name = "ca-download";
                    mountPath = "/etc/core/ca";
                  }
                  {
                    name = "secret-key";
                    mountPath = "/etc/core/key";
                    subPath = "key";
                  }
                  {
                    name = "token-service-private-key";
                    mountPath = "/etc/core/private_key.pem";
                    subPath = "tls.key";
                  }
                  {
                    name = "psc";
                    mountPath = "/etc/core/token";
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
              }
            ];
            volumes = [
              {
                name = "ca-download";
              }
              {
                name = "config";
                configMap = {
                  name = self.coreConfigMap.out.name;
                  items = [
                    {
                      key = "app.conf";
                      path = "app.conf";
                    }
                  ];
                };
              }
              {
                name = "psc";
              }
              {
                name = "secret-key";
                secret = {
                  secretName = self.coreSecret.out.name;
                  items = [
                    {
                      key = "secretKey";
                      path = "key";
                    }
                  ];
                };
              }
              {
                name = "token-service-private-key";
                secret = {
                  secretName = config.ingress.tls.secretName;
                };
              }
            ];
          };
        };
      };
    };

    # ============================================================
    # Portal -- Web UI (nginx)
    # ============================================================

    portalConfigMap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-portal";
      labels = componentLabels "portal";
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

    portalService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-portal";
      labels = componentLabels "portal";
      spec = {
        type = "ClusterIP";
        selector = componentSelectorLabels "portal";
        ports = [
          {
            port = portalServicePort;
            targetPort = 8080;
            protocol = "TCP";
          }
        ];
      };
    };

    portalDeployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-portal";
      labels = componentLabels "portal";
      spec = {
        replicas = config.portal.replicas;
        revisionHistoryLimit = 5;
        selector.matchLabels = componentSelectorLabels "portal";
        template = {
          metadata.labels = componentLabels "portal";
          spec = {
            securityContext = {
              runAsUser = 10000;
              fsGroup = 10000;
            };
            automountServiceAccountToken = false;
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
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 300;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 1;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                volumeMounts = [
                  {
                    name = "portal-config";
                    mountPath = "/etc/nginx/nginx.conf";
                    subPath = "nginx.conf";
                  }
                ];
                securityContext = containerSecurityContext;
              }
            ];
            volumes = [
              {
                name = "portal-config";
                configMap.name = self.portalConfigMap.out.name;
              }
            ];
          };
        };
      };
    };

    # ============================================================
    # Registry -- OCI image storage
    # ============================================================

    registryPVC = scope.mkResource {
      apiVersion = "v1";
      kind = "PersistentVolumeClaim";
      name = "${name}-registry";
      labels = componentLabels "registry";
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
      labels = componentLabels "registry";
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

    registrySecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-registry";
      labels = componentLabels "registry";
      extra = {
        type = "Opaque";
        stringData = {
          REGISTRY_HTTP_SECRET = "placeholder-http-secret";
          REGISTRY_HTPASSWD = "harbor_registry_user:$2y$10$placeholder_bcrypt_hash";
        };
      };
    };

    registryHtpasswdSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-registry-htpasswd";
      labels = componentLabels "registry";
      extra = {
        type = "Opaque";
        stringData = {
          REGISTRY_HTPASSWD = "harbor_registry_user:$2y$10$placeholder_bcrypt_hash";
        };
      };
    };

    registryService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-registry";
      labels = componentLabels "registry";
      spec = {
        type = "ClusterIP";
        selector = componentSelectorLabels "registry";
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
      };
    };

    registryDeployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-registry";
      labels = componentLabels "registry";
      spec = {
        replicas = config.registry.replicas;
        revisionHistoryLimit = 5;
        strategy.type = "Recreate";
        selector.matchLabels = componentSelectorLabels "registry";
        template = {
          metadata.labels = componentLabels "registry";
          spec = {
            securityContext = {
              runAsUser = 10000;
              fsGroup = 10000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            automountServiceAccountToken = false;
            terminationGracePeriodSeconds = 120;
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
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = 5000;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 300;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = 5000;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 1;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                envFrom = [
                  { secretRef.name = self.registrySecret.out.name; }
                ];
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
                livenessProbe = {
                  httpGet = {
                    path = "/api/health";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 300;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/health";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 1;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                env = [
                  {
                    name = "CORE_SECRET";
                    valueFrom.secretKeyRef = {
                      name = self.coreSecret.out.name;
                      key = "secret";
                    };
                  }
                  {
                    name = "JOBSERVICE_SECRET";
                    valueFrom.secretKeyRef = {
                      name = self.jobserviceSecret.out.name;
                      key = "JOBSERVICE_SECRET";
                    };
                  }
                ];
                envFrom = [
                  { configMapRef.name = self.registryCtlConfigMap.out.name; }
                  { secretRef.name = self.registrySecret.out.name; }
                  { secretRef.name = self.registryCtlSecret.out.name; }
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
      };
    };

    registryCtlConfigMap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-registryctl";
      labels = componentLabels "registry";
    };

    registryCtlSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-registryctl";
      labels = componentLabels "registry";
      extra = {
        type = "Opaque";
        stringData = { };
      };
    };

    # ============================================================
    # Jobservice -- Async jobs (replication, GC, scan)
    # ============================================================

    jobserviceConfigMap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-jobservice";
      labels = componentLabels "jobservice";
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
      labels = componentLabels "jobservice";
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

    jobserviceSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-jobservice";
      labels = componentLabels "jobservice";
      extra = {
        type = "Opaque";
        stringData = {
          CORE_SECRET = "not-a-secure-secret";
          JOBSERVICE_SECRET = "not-a-secure-secret";
          REGISTRY_CREDENTIAL_PASSWORD = "harbor_registry_password";
        };
      };
    };

    jobserviceService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-jobservice";
      labels = componentLabels "jobservice";
      spec = {
        type = "ClusterIP";
        selector = componentSelectorLabels "jobservice";
        ports = [
          {
            name = "http-jobservice";
            port = jobserviceServicePort;
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
      };
    };

    jobservicePVC = scope.mkResource {
      apiVersion = "v1";
      kind = "PersistentVolumeClaim";
      name = "${name}-jobservice";
      labels = componentLabels "jobservice";
      spec = {
        accessModes = [ "ReadWriteOnce" ];
        resources.requests.storage = config.persistence.jobservice.size;
      }
      // lib.optionalAttrs (config.persistence.jobservice.storageClass != null) {
        storageClassName = config.persistence.jobservice.storageClass;
      };
    };

    jobserviceDeployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-jobservice";
      labels = componentLabels "jobservice";
      spec = {
        replicas = config.jobservice.replicas;
        revisionHistoryLimit = 5;
        strategy = {
          type = "Recreate";
        };
        selector.matchLabels = componentSelectorLabels "jobservice";
        template = {
          metadata.labels = componentLabels "jobservice";
          spec = {
            securityContext = {
              runAsUser = 10000;
              fsGroup = 10000;
            };
            automountServiceAccountToken = false;
            terminationGracePeriodSeconds = 120;
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
                livenessProbe = {
                  httpGet = {
                    path = "/api/v1/stats";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 300;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/api/v1/stats";
                    port = 8080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                env = [
                  {
                    name = "CORE_SECRET";
                    valueFrom.secretKeyRef = {
                      name = self.coreSecret.out.name;
                      key = "secret";
                    };
                  }
                ];
                envFrom = [
                  { configMapRef.name = self.jobserviceEnvConfigMap.out.name; }
                  { secretRef.name = self.jobserviceSecret.out.name; }
                ];
                volumeMounts = [
                  {
                    name = "jobservice-config";
                    mountPath = "/etc/jobservice/config.yml";
                    subPath = "config.yml";
                  }
                  {
                    name = "job-logs";
                    mountPath = "/var/log/jobs";
                  }
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
            volumes = [
              {
                name = "jobservice-config";
                configMap.name = self.jobserviceConfigMap.out.name;
              }
              {
                name = "job-logs";
                persistentVolumeClaim.claimName = self.jobservicePVC.out.name;
              }
            ];
          };
        };
      };
    };

    # ============================================================
    # Exporter -- Prometheus metrics exporter
    # ============================================================

    exporterSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-exporter";
      labels = componentLabels "exporter";
      extra = {
        type = "Opaque";
        stringData = { };
      };
    };

    # ============================================================
    # Redis -- Internal cache (only when redis.type = "internal")
    # ============================================================

    redisService =
      if useInternalRedis then
        scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-redis";
          labels = componentLabels "redis";
          spec = {
            type = "ClusterIP";
            selector = componentSelectorLabels "redis";
            ports = [
              {
                port = 6379;
                targetPort = 6379;
                protocol = "TCP";
              }
            ];
          };
        }
      else
        null;

    redisStatefulSet =
      if useInternalRedis then
        scope.mkResource {
          apiVersion = "apps/v1";
          kind = "StatefulSet";
          name = "${name}-redis";
          labels = componentLabels "redis";
          spec = {
            replicas = 1;
            serviceName = "${name}-redis";
            selector.matchLabels = componentSelectorLabels "redis";
            template = {
              metadata.labels = componentLabels "redis";
              spec = {
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
                      failureThreshold = 3;
                    };
                    readinessProbe = {
                      tcpSocket.port = 6379;
                      initialDelaySeconds = 1;
                      periodSeconds = 10;
                      failureThreshold = 3;
                    };
                    volumeMounts = [
                      {
                        name = "data";
                        mountPath = "/var/lib/redis";
                      }
                    ];
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
                    securityContext = containerSecurityContext;
                  }
                ];
              };
            };
            volumeClaimTemplates = [
              {
                metadata = {
                  name = "data";
                  labels = helmSelectorLabels;
                };
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = config.persistence.redis.size;
                }
                // lib.optionalAttrs (config.persistence.redis.storageClass != null) {
                  storageClassName = config.persistence.redis.storageClass;
                };
              }
            ];
          };
        }
      else
        null;

    # ============================================================
    # Ingress -- Route to core API and portal UI
    # ============================================================

    ingress =
      if config.ingress.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          name = "${name}-ingress";
          labels = commonLabels;
          annotations = {
            "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
          };
          spec = {
            ingressClassName = config.ingress.className;
            rules = [
              {
                host = config.ingress.hosts.core;
                http.paths = [
                  {
                    path = "/api/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "${name}-core";
                      port.number = coreServicePort;
                    };
                  }
                  {
                    path = "/service/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "${name}-core";
                      port.number = coreServicePort;
                    };
                  }
                  {
                    path = "/v2/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "${name}-core";
                      port.number = coreServicePort;
                    };
                  }
                  {
                    path = "/c/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "${name}-core";
                      port.number = coreServicePort;
                    };
                  }
                  {
                    path = "/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "${name}-portal";
                      port.number = portalServicePort;
                    };
                  }
                ];
              }
            ];
          }
          // lib.optionalAttrs (config.ingress.tls.enabled) {
            tls = [
              {
                hosts = [ config.ingress.hosts.core ];
                secretName = config.ingress.tls.secretName;
              }
            ];
          };
          requires = [
            self.coreService
            self.portalService
          ];
        }
      else
        null;

    # ============================================================
    # Entry point
    # ============================================================

    main = {
      resource = if config.ingress.enabled then self.ingress else self.coreService;
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
      ]
      ++ lib.optionals useInternalRedis [
        self.redisStatefulSet
        self.redisService
      ]
      ++ lib.optional config.ingress.enabled self.ingress;
    };
  };
}
