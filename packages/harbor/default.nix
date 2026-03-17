# Harbor container registry kix package.
#
# Multi-component OCI registry: Core (API/auth), Portal (web UI),
# Registry (image storage), Jobservice (async tasks), Trivy (scanner),
# Redis (internal cache), and Ingress.
#
# Resources per component:
#   Core       — Deployment, Service, ConfigMap, Secret
#   Portal     — Deployment, Service, ConfigMap
#   Registry   — Deployment, Service, ConfigMap, Secret, PVC
#   Jobservice — Deployment, Service, ConfigMap, Secret
#   Trivy      — StatefulSet, Service, Secret
#   Redis      — StatefulSet, Service, PVC (when type=internal)
#   Ingress    — Ingress
#   Shared     — ServiceAccount
#
# main = Ingress (or core Service when ingress disabled)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;

  cfg = scope.defaults config {
    externalURL = "https://harbor.example.com";

    core.image = {
      repository = "goharbor/harbor-core";
      tag = "v2.12.2";
    };
    portal.image = {
      repository = "goharbor/harbor-portal";
      tag = "v2.12.2";
    };
    registry.image = {
      repository = "goharbor/harbor-registryctl";
      tag = "v2.12.2";
    };
    jobservice.image = {
      repository = "goharbor/harbor-jobservice";
      tag = "v2.12.2";
    };
    trivy.image = {
      repository = "goharbor/trivy-adapter";
      tag = "v2.12.2";
    };
    redis.image = {
      repository = "goharbor/redis-photon";
      tag = "v2.12.2";
    };

    core.replicas = 1;
    portal.replicas = 1;
    registry.replicas = 1;
    jobservice.replicas = 1;

    persistence = {
      registry = {
        size = "200Gi";
        storageClass = null;
      };
      redis = {
        size = "2Gi";
        storageClass = null;
      };
    };

    ingress = {
      enabled = true;
      className = "public-v2";
      hosts = {
        core = "harbor.example.com";
      };
      tls = {
        enabled = true;
        secretName = "harbor-tls";
      };
    };

    database = {
      type = "external";
      external = {
        host = "";
        port = "5432";
        username = "harbor";
        existingSecret = null;
        sslmode = "disable";
      };
    };

    redis = {
      type = "internal";
      external = {
        host = "";
        port = "6379";
      };
    };

    secretKey = null;
    adminPassword = null;
  };

  # --- Derived values ---

  useInternalRedis = cfg.redis.type == "internal";

  redisHost =
    if useInternalRedis then "${name}-redis.${ns}.svc.cluster.local" else cfg.redis.external.host;
  redisPort = if useInternalRedis then "6379" else cfg.redis.external.port;
  redisURL = "redis://${redisHost}:${redisPort}";

  coreInternalURL = "http://${name}-core:8080";
  registryInternalURL = "http://${name}-registry:5000";
  portalInternalURL = "http://${name}-portal:8080";
  jobserviceInternalURL = "http://${name}-jobservice:8080";
  trivyInternalURL = "http://${name}-trivy:8080";
  tokenServiceURL = "${coreInternalURL}/service/token";
  registryTokenServiceURL = "${cfg.externalURL}/service/token";

  # Common labels for all resources.
  commonLabels = {
    "app.kubernetes.io/name" = "harbor";
    "app.kubernetes.io/instance" = name;
  };

  # Per-component selector labels.
  componentLabels =
    component:
    commonLabels
    // {
      "app.kubernetes.io/component" = component;
    };

in
self: {

  # ============================================================
  # Shared ServiceAccount
  # ============================================================

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-harbor";
    labels = commonLabels;
  };

  # ============================================================
  # Core — API server, auth, project management
  # ============================================================

  coreConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-core";
    labels = componentLabels "core";
    data = {
      EXT_ENDPOINT = cfg.externalURL;
      CORE_URL = coreInternalURL;
      JOBSERVICE_URL = jobserviceInternalURL;
      REGISTRY_URL = registryInternalURL;
      TOKEN_SERVICE_URL = tokenServiceURL;
      PORTAL_URL = portalInternalURL;
      TRIVY_ADAPTER_URL = trivyInternalURL;
      REGISTRY_STORAGE_PROVIDER_NAME = "filesystem";
      WITH_TRIVY = "true";
      CORE_LOCAL_URL = "http://127.0.0.1:8080";
      REGISTRY_CREDENTIAL_USERNAME = "harbor_registry_user";

      # Database
      DATABASE_TYPE = "postgresql";
      POSTGRESQL_HOST = cfg.database.external.host;
      POSTGRESQL_PORT = cfg.database.external.port;
      POSTGRESQL_USERNAME = cfg.database.external.username;
      POSTGRESQL_SSLMODE = cfg.database.external.sslmode;
      POSTGRESQL_DATABASE = "registry";

      # Redis
      _REDIS_URL_CORE = "${redisURL}/0";
      _REDIS_URL_REG = "${redisURL}/1";

      # Auth
      AUTH_MODE = "db_auth";
      CFG_EXPIRATION = "5";
      MAX_JOB_WORKERS = "10";
      PERMITTED_REGISTRY_TYPES_FOR_PROXY_CACHE = "docker-hub,harbor,azure-acr,aws-ecr,google-gcr,quay,docker-registry,github-ghcr,jfrog-artifactory";

      LOG_LEVEL = "info";
      HTTP_PROXY = "";
      HTTPS_PROXY = "";
      NO_PROXY = "127.0.0.1,localhost,.local,.internal,${name}-core,${name}-jobservice,${name}-registry,${name}-portal,${name}-trivy,${name}-redis";

      CHART_CACHE_DRIVER = "redis";
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
        HARBOR_ADMIN_PASSWORD = if cfg.adminPassword != null then cfg.adminPassword else "Harbor12345";
        secretKey = if cfg.secretKey != null then cfg.secretKey else "not-a-secure-key!";
        secret = "not-a-secure-key!";
        CSRF_KEY = "not-a-secure-csrf-key-change-me!";
        REGISTRY_CREDENTIAL_PASSWORD = "harbor_registry_password";
      }
      // lib.optionalAttrs (cfg.database.external.existingSecret == null) {
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
      selector = componentLabels "core";
      ports = [
        {
          name = "http";
          port = 8080;
          targetPort = 8080;
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
      replicas = cfg.core.replicas;
      revisionHistoryLimit = 5;
      selector.matchLabels = componentLabels "core";
      template = {
        metadata.labels = componentLabels "core";
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          automountServiceAccountToken = false;
          terminationGracePeriodSeconds = 120;
          containers = [
            {
              name = "core";
              image = "${cfg.core.image.repository}:${cfg.core.image.tag}";
              imagePullPolicy = "IfNotPresent";
              livenessProbe = {
                httpGet = {
                  path = "/api/v2.0/ping";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 20;
                periodSeconds = 10;
                failureThreshold = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/api/v2.0/ping";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 20;
                periodSeconds = 10;
                failureThreshold = 10;
              };
              envFrom = [
                { configMapRef.name = "${self.coreConfigMap}"; }
                { secretRef.name = "${self.coreSecret}"; }
              ];
              env = lib.optionals (cfg.database.external.existingSecret != null) [
                {
                  name = "POSTGRESQL_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = cfg.database.external.existingSecret;
                    key = "password";
                  };
                }
              ];
              ports = [
                {
                  containerPort = 8080;
                  name = "http";
                }
              ];
              volumeMounts = [
                {
                  name = "config";
                  mountPath = "/etc/core/app.conf";
                  subPath = "app.conf";
                }
                {
                  name = "psc";
                  mountPath = "/etc/core/token";
                }
              ];
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                limits = {
                  memory = "512Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
            }
          ];
          volumes = [
            {
              name = "config";
              configMap = {
                name = "${self.coreConfigMap}";
                items = [
                  {
                    key = "EXT_ENDPOINT";
                    path = "app.conf";
                  }
                ];
              };
            }
            {
              name = "psc";
              emptyDir = { };
            }
          ];
        };
      };
    };
    requires = [
      self.coreConfigMap
      self.coreSecret
      self.serviceAccount
    ];
  };

  # ============================================================
  # Portal — Web UI (nginx)
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
          worker_connections 1024;
        }

        http {
          client_body_temp_path /tmp/client_body_temp;
          proxy_temp_path /tmp/proxy_temp;
          fastcgi_temp_path /tmp/fastcgi_temp;
          uwsgi_temp_path /tmp/uwsgi_temp;
          scgi_temp_path /tmp/scgi_temp;
          server {
            listen 8080;
            server_name localhost;
            root /usr/share/nginx/html;
            index index.html index.htm;
            include /etc/nginx/mime.types;

            # Disable caching by default
            add_header Cache-Control "no-store";
            add_header Pragma "no-cache";

            location / {
              try_files $uri /index.html;
            }

            location /c/ {
              proxy_pass ${coreInternalURL}/c/;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_buffering off;
              proxy_request_buffering off;
            }

            location /api/ {
              proxy_pass ${coreInternalURL}/api/;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_buffering off;
              proxy_request_buffering off;
            }
          }
        }
      '';
    };
  };

  portalService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-portal";
    labels = componentLabels "portal";
    spec = {
      type = "ClusterIP";
      selector = componentLabels "portal";
      ports = [
        {
          name = "http";
          port = 8080;
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
      replicas = cfg.portal.replicas;
      revisionHistoryLimit = 5;
      selector.matchLabels = componentLabels "portal";
      template = {
        metadata.labels = componentLabels "portal";
        spec = {
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          automountServiceAccountToken = false;
          containers = [
            {
              name = "portal";
              image = "${cfg.portal.image.repository}:${cfg.portal.image.tag}";
              imagePullPolicy = "IfNotPresent";
              ports = [
                {
                  containerPort = 8080;
                  name = "http";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 1;
                periodSeconds = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 1;
                periodSeconds = 10;
              };
              volumeMounts = [
                {
                  name = "portal-config";
                  mountPath = "/etc/nginx/nginx.conf";
                  subPath = "nginx.conf";
                }
              ];
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "64Mi";
                };
                limits = {
                  memory = "128Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
            }
          ];
          volumes = [
            {
              name = "portal-config";
              configMap.name = "${self.portalConfigMap}";
            }
          ];
        };
      };
    };
    requires = [ self.portalConfigMap ];
  };

  # ============================================================
  # Registry — OCI image storage
  # ============================================================

  registryPVC = scope.mkResource {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    name = "${name}-registry";
    labels = componentLabels "registry";
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.persistence.registry.size;
    }
    // lib.optionalAttrs (cfg.persistence.registry.storageClass != null) {
      storageClassName = cfg.persistence.registry.storageClass;
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
          accesslog:
            disabled: false
          level: info
          formatter: text
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
          db: 1
        http:
          addr: :5000
          relativeurls: false
          debug:
            addr: :5001
            prometheus:
              enabled: true
              path: /metrics
        auth:
          token:
            issuer: harbor-token-issuer
            realm: ${registryTokenServiceURL}
            rootcertbundle: /etc/registry/root.crt
            service: harbor-registry
        notifications:
          endpoints:
            - name: harbor
              disabled: false
              url: ${coreInternalURL}/service/notifications
              timeout: 3000ms
              threshold: 5
              backoff: 1s
        compatibility:
          schema1:
            enabled: true
      '';
      "ctl-config.yml" = ''
        ---
        protocol: "http"
        port: 8080
        log_level: info
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

  registryService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-registry";
    labels = componentLabels "registry";
    spec = {
      type = "ClusterIP";
      selector = componentLabels "registry";
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
      ];
    };
  };

  registryDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-registry";
    labels = componentLabels "registry";
    spec = {
      replicas = cfg.registry.replicas;
      revisionHistoryLimit = 5;
      strategy.type = "RollingUpdate";
      selector.matchLabels = componentLabels "registry";
      template = {
        metadata.labels = componentLabels "registry";
        spec = {
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          serviceAccountName = "${self.serviceAccount}";
          automountServiceAccountToken = false;
          terminationGracePeriodSeconds = 120;
          containers = [
            {
              name = "registry";
              image = "goharbor/registry-photon:${cfg.registry.image.tag}";
              imagePullPolicy = "IfNotPresent";
              ports = [
                {
                  containerPort = 5000;
                  name = "http";
                }
                {
                  containerPort = 5001;
                  name = "debug";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/";
                  port = 5000;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/";
                  port = 5000;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
              };
              env = [
                {
                  name = "REGISTRY_HTTP_SECRET";
                  valueFrom.secretKeyRef = {
                    name = "${self.registrySecret}";
                    key = "REGISTRY_HTTP_SECRET";
                  };
                }
              ];
              volumeMounts = [
                {
                  name = "registry-data";
                  mountPath = "/storage";
                  subPath = "";
                }
                {
                  name = "registry-config";
                  mountPath = "/etc/registry/config.yml";
                  subPath = "config.yml";
                }
                {
                  name = "registry-htpasswd";
                  mountPath = "/etc/registry/passwd";
                  subPath = "REGISTRY_HTPASSWD";
                }
              ];
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                limits = {
                  memory = "512Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
            }
            {
              name = "registryctl";
              image = "${cfg.registry.image.repository}:${cfg.registry.image.tag}";
              imagePullPolicy = "IfNotPresent";
              ports = [
                {
                  containerPort = 8080;
                  name = "http-ctl";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/api/health";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/api/health";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
              };
              env = [
                {
                  name = "REGISTRY_HTTP_SECRET";
                  valueFrom.secretKeyRef = {
                    name = "${self.registrySecret}";
                    key = "REGISTRY_HTTP_SECRET";
                  };
                }
              ];
              volumeMounts = [
                {
                  name = "registry-data";
                  mountPath = "/storage";
                  subPath = "";
                }
                {
                  name = "registry-config";
                  mountPath = "/etc/registry/config.yml";
                  subPath = "config.yml";
                }
                {
                  name = "registryctl-config";
                  mountPath = "/etc/registryctl/config.yml";
                  subPath = "ctl-config.yml";
                }
              ];
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "64Mi";
                };
                limits = {
                  memory = "128Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
            }
          ];
          volumes = [
            {
              name = "registry-data";
              persistentVolumeClaim.claimName = "${self.registryPVC}";
            }
            {
              name = "registry-config";
              configMap.name = "${self.registryConfigMap}";
            }
            {
              name = "registryctl-config";
              configMap.name = "${self.registryConfigMap}";
            }
            {
              name = "registry-htpasswd";
              secret.secretName = "${self.registrySecret}";
            }
          ];
        };
      };
    };
    requires = [
      self.registryConfigMap
      self.registrySecret
      self.registryPVC
      self.serviceAccount
    ];
  };

  # ============================================================
  # Jobservice — Async jobs (replication, GC, scan)
  # ============================================================

  jobserviceConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-jobservice";
    labels = componentLabels "jobservice";
    data = {
      "config.yml" = ''
        ---
        protocol: "http"
        port: 8080
        worker_pool:
          workers: 10
          backend: "redis"
          redis_pool:
            redis_url: ${redisURL}/2
            namespace: "harbor_job_service_namespace"
            idle_timeout_second: 3600
        job_loggers:
          - name: "STD_OUTPUT"
            level: INFO
        loggers:
          - name: "STD_OUTPUT"
            level: INFO
      '';
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
      selector = componentLabels "jobservice";
      ports = [
        {
          name = "http";
          port = 8080;
          targetPort = 8080;
          protocol = "TCP";
        }
      ];
    };
  };

  jobserviceDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-jobservice";
    labels = componentLabels "jobservice";
    spec = {
      replicas = cfg.jobservice.replicas;
      revisionHistoryLimit = 5;
      strategy = {
        type = "RollingUpdate";
      };
      selector.matchLabels = componentLabels "jobservice";
      template = {
        metadata.labels = componentLabels "jobservice";
        spec = {
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          serviceAccountName = "${self.serviceAccount}";
          automountServiceAccountToken = false;
          terminationGracePeriodSeconds = 120;
          containers = [
            {
              name = "jobservice";
              image = "${cfg.jobservice.image.repository}:${cfg.jobservice.image.tag}";
              imagePullPolicy = "IfNotPresent";
              ports = [
                {
                  containerPort = 8080;
                  name = "http";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/api/v1/stats";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 20;
                periodSeconds = 10;
                failureThreshold = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/api/v1/stats";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 20;
                periodSeconds = 10;
                failureThreshold = 10;
              };
              envFrom = [
                { secretRef.name = "${self.jobserviceSecret}"; }
              ];
              env = [
                {
                  name = "CORE_URL";
                  value = coreInternalURL;
                }
                {
                  name = "TOKEN_SERVICE_URL";
                  value = tokenServiceURL;
                }
                {
                  name = "REGISTRY_URL";
                  value = registryInternalURL;
                }
                {
                  name = "REGISTRY_CONTROLLER_URL";
                  value = "http://${name}-registry:8080";
                }
                {
                  name = "REGISTRY_CREDENTIAL_USERNAME";
                  value = "harbor_registry_user";
                }
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
                  cpu = "50m";
                  memory = "128Mi";
                };
                limits = {
                  memory = "256Mi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
            }
          ];
          volumes = [
            {
              name = "jobservice-config";
              configMap.name = "${self.jobserviceConfigMap}";
            }
            {
              name = "job-logs";
              emptyDir = { };
            }
          ];
        };
      };
    };
    requires = [
      self.jobserviceConfigMap
      self.jobserviceSecret
      self.serviceAccount
    ];
  };

  # ============================================================
  # Trivy — Vulnerability scanner
  # ============================================================

  trivySecret = scope.mkResource {
    apiVersion = "v1";
    kind = "Secret";
    name = "${name}-trivy";
    labels = componentLabels "trivy";
    extra = {
      type = "Opaque";
      stringData = {
        SCANNER_STORE_REDIS_URL = "${redisURL}/5";
        SCANNER_JOB_QUEUE_REDIS_URL = "${redisURL}/5";
      };
    };
  };

  trivyService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-trivy";
    labels = componentLabels "trivy";
    spec = {
      type = "ClusterIP";
      selector = componentLabels "trivy";
      ports = [
        {
          name = "http";
          port = 8080;
          targetPort = 8080;
          protocol = "TCP";
        }
      ];
    };
  };

  trivyStatefulSet = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${name}-trivy";
    labels = componentLabels "trivy";
    spec = {
      replicas = 1;
      serviceName = "${name}-trivy";
      selector.matchLabels = componentLabels "trivy";
      template = {
        metadata.labels = componentLabels "trivy";
        spec = {
          securityContext = {
            runAsUser = 10000;
            fsGroup = 10000;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          automountServiceAccountToken = false;
          containers = [
            {
              name = "trivy";
              image = "${cfg.trivy.image.repository}:${cfg.trivy.image.tag}";
              imagePullPolicy = "IfNotPresent";
              ports = [
                {
                  containerPort = 8080;
                  name = "http";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/probe/healthy";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
                failureThreshold = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/probe/ready";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
                failureThreshold = 3;
              };
              envFrom = [
                { secretRef.name = "${self.trivySecret}"; }
              ];
              env = [
                {
                  name = "HTTP_PROXY";
                  value = "";
                }
                {
                  name = "HTTPS_PROXY";
                  value = "";
                }
                {
                  name = "NO_PROXY";
                  value = "127.0.0.1,localhost,.local,.internal";
                }
                {
                  name = "SCANNER_LOG_LEVEL";
                  value = "info";
                }
                {
                  name = "SCANNER_TRIVY_CACHE_DIR";
                  value = "/home/scanner/.cache/trivy";
                }
                {
                  name = "SCANNER_TRIVY_REPORTS_DIR";
                  value = "/home/scanner/.cache/reports";
                }
                {
                  name = "SCANNER_TRIVY_VULN_TYPE";
                  value = "os,library";
                }
                {
                  name = "SCANNER_TRIVY_SEVERITY";
                  value = "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL";
                }
                {
                  name = "SCANNER_TRIVY_TIMEOUT";
                  value = "5m0s";
                }
              ];
              volumeMounts = [
                {
                  name = "data";
                  mountPath = "/home/scanner/.cache";
                }
              ];
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "256Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "1Gi";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
              };
            }
          ];
        };
      };
      volumeClaimTemplates = [
        {
          metadata = {
            name = "data";
            labels = componentLabels "trivy";
          };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = "5Gi";
          };
        }
      ];
    };
    requires = [ self.trivySecret ];
  };

  # ============================================================
  # Redis — Internal cache (only when redis.type = "internal")
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
          selector = componentLabels "redis";
          ports = [
            {
              name = "redis";
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
          selector.matchLabels = componentLabels "redis";
          template = {
            metadata.labels = componentLabels "redis";
            spec = {
              securityContext = {
                runAsUser = 999;
                fsGroup = 999;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              automountServiceAccountToken = false;
              containers = [
                {
                  name = "redis";
                  image = "${cfg.redis.image.repository}:${cfg.redis.image.tag}";
                  imagePullPolicy = "IfNotPresent";
                  ports = [
                    {
                      containerPort = 6379;
                      name = "redis";
                    }
                  ];
                  livenessProbe = {
                    exec.command = [
                      "redis-cli"
                      "ping"
                    ];
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    exec.command = [
                      "redis-cli"
                      "ping"
                    ];
                    initialDelaySeconds = 10;
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
                      cpu = "50m";
                      memory = "64Mi";
                    };
                    limits = {
                      memory = "256Mi";
                    };
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                  };
                }
              ];
            };
          };
          volumeClaimTemplates = [
            {
              metadata = {
                name = "data";
                labels = componentLabels "redis";
              };
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = cfg.persistence.redis.size;
              }
              // lib.optionalAttrs (cfg.persistence.redis.storageClass != null) {
                storageClassName = cfg.persistence.redis.storageClass;
              };
            }
          ];
        };
      }
    else
      null;

  # ============================================================
  # Ingress — Route to core API and portal UI
  # ============================================================

  ingress =
    if cfg.ingress.enabled then
      scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "${name}-harbor";
        labels = commonLabels;
        annotations = {
          "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
          "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
        };
        spec = {
          ingressClassName = cfg.ingress.className;
          rules = [
            {
              host = cfg.ingress.hosts.core;
              http.paths = [
                {
                  path = "/api/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-core";
                    port.number = 8080;
                  };
                }
                {
                  path = "/service/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-core";
                    port.number = 8080;
                  };
                }
                {
                  path = "/v2/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-core";
                    port.number = 8080;
                  };
                }
                {
                  path = "/chartrepo/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-core";
                    port.number = 8080;
                  };
                }
                {
                  path = "/c/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-core";
                    port.number = 8080;
                  };
                }
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${name}-portal";
                    port.number = 8080;
                  };
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs (cfg.ingress.tls.enabled) {
          tls = [
            {
              hosts = [ cfg.ingress.hosts.core ];
              secretName = cfg.ingress.tls.secretName;
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
    resource = if cfg.ingress.enabled then self.ingress else self.coreService;
    requires = [
      self.coreDeployment
      self.coreService
      self.portalDeployment
      self.portalService
      self.registryDeployment
      self.registryService
      self.jobserviceDeployment
      self.jobserviceService
      self.trivyStatefulSet
      self.trivyService
      self.serviceAccount
    ]
    ++ lib.optionals useInternalRedis [
      self.redisStatefulSet
      self.redisService
    ]
    ++ lib.optional cfg.ingress.enabled self.ingress;
  };
}
