# Harbor container registry kix package.
#
# Multi-component OCI registry: Core (API/auth), Portal (web UI),
# Registry (image storage), Jobservice (async tasks), and Ingress.
#
# Dependencies:
#   postgres       — required, database
#   redis          — required, cache (valkey or redis instance via DI)
#   ingressNginx   — optional, provides IngressClass for ingress
#   clusterIssuer  — optional, provides withCert transformer for TLS
#
# Resources per component:
#   Core       -- Deployment, Service, ConfigMap, Secret
#   Portal     -- Deployment, Service, ConfigMap
#   Registry   -- Deployment, Service, ConfigMap, Secret, PVC
#   Jobservice -- Deployment, Service, ConfigMap, Secret, PVC
#   Ingress    -- Ingress (optional)
#
# main = Ingress (or core Service when ingress disabled)

{
  scope,
  lib,
  kix,
  postgres,
  redis,
  ingressNginx ? null,
  clusterIssuer ? null,
}:

let
  name = scope.instanceName;
in
{
  options = {
    externalURL = lib.mkOption {
      type = lib.types.str;
      default = "https://harbor.example.com";
    };

    core = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = { repository = "goharbor/harbor-core"; tag = "v2.12.2"; };
      };
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
    };

    portal = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = { repository = "goharbor/harbor-portal"; tag = "v2.12.2"; };
      };
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
    };

    registry = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = { repository = "goharbor/harbor-registryctl"; tag = "v2.12.2"; };
      };
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
    };

    jobservice = {
      image = lib.mkOption {
        type = lib.types.anything;
        default = { repository = "goharbor/harbor-jobservice"; tag = "v2.12.2"; };
      };
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
    };

    trivy = {
      enabled = lib.mkOption { type = lib.types.bool; default = false; };
    };

    metrics = {
      enabled = lib.mkOption { type = lib.types.bool; default = true; };
      port = lib.mkOption { type = lib.types.int; default = 8001; };
    };

    persistence = {
      registry = lib.mkOption {
        type = lib.types.anything;
        default = { size = "200Gi"; storageClass = null; };
      };
      jobservice = lib.mkOption {
        type = lib.types.anything;
        default = { size = "1Gi"; storageClass = null; };
      };
    };

    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        host = "harbor.example.com";
        tls = { enabled = true; secretName = "harbor-ingress"; };
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

    secretKey = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    adminPassword = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  };

  build = { self, config, clusterConfig }:
  let
    # --- Derived values ---

    redisHost = redis.out.fqdn;
    redisPort = redis.out.port;
    dbHost = if config.database.host != null then config.database.host else postgres.out.fqdn;
    noProxy = "${name}-core,${name}-jobservice,${name}-database,${name}-registry,${name}-portal,${name}-trivy,${name}-exporter,127.0.0.1,localhost,.local,.internal";

    # Internal URLs derived from service resources for dependency tracking.
    coreInternalURL = "http://${self.coreService.out.name}:80";
    registryInternalURL = "http://${self.registryService.out.name}:5000";
    registryCtlInternalURL = "http://${self.registryService.out.name}:8080";
    portalInternalURL = "http://${self.portalService.out.name}";
    jobserviceInternalURL = "http://${self.jobserviceService.out.name}";
    tokenServiceURL = "${coreInternalURL}/service/token";

    # --- Shared let bindings ---

    selectorLabels = { app = "harbor"; release = name; };

    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      privileged = false;
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };

    harborPodDefaults = {
      securityContext = { runAsUser = 10000; fsGroup = 10000; };
      automountServiceAccountToken = false;
      terminationGracePeriodSeconds = 120;
    };

    # Per-component probes — base holds shared thresholds,
    # each component overrides httpGet. Sites add initialDelaySeconds via //.
    probeBase = { httpGet = { scheme = "HTTP"; port = 8080; }; periodSeconds = 10; failureThreshold = 3; };
    coreProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v2.0/ping"; };
    portalProbe = lib.recursiveUpdate probeBase { httpGet.path = "/"; };
    registryProbe = lib.recursiveUpdate probeBase { httpGet = { path = "/"; port = 5000; }; };
    registryCtlProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/health"; };
    jobserviceProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v1/stats"; };


  in
  {

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

    coreSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-core";
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
      spec = {
        type = "ClusterIP";
        selector = selectorLabels // { component = "core"; };
        ports = [
          { name = "http-web"; port = 80; targetPort = 8080; protocol = "TCP"; }
        ]
        ++ lib.optionals config.metrics.enabled [
          { name = "http-metrics"; port = config.metrics.port; targetPort = config.metrics.port; protocol = "TCP"; }
        ];
      };
      outputs.port = "80";
    };

    # --- Core mounts ---
    coreConfigMount = kix.mount.configMap self.coreConfigMap {
      name = "config"; mountPath = "/etc/core/app.conf"; subPath = "app.conf";
      items = [{ key = "app.conf"; path = "app.conf"; }];
    };
    coreSecretKeyMount = kix.mount.secret self.coreSecret {
      name = "secret-key"; mountPath = "/etc/core/key"; subPath = "key";
      items = [{ key = "secretKey"; path = "key"; }];
    };

    coreDeployment =
      {
        name = "${name}-core";
        spec = {
          replicas = config.core.replicas;
          revisionHistoryLimit = 5;
          selector.matchLabels = selectorLabels // { component = "core"; };
          template.spec = harborPodDefaults // {
            containers = [
              {
                name = "core";
                image = "${config.core.image.repository}:${config.core.image.tag}";
                imagePullPolicy = "IfNotPresent";
                livenessProbe = coreProbe;
                readinessProbe = coreProbe;
                startupProbe = coreProbe // { initialDelaySeconds = 10; failureThreshold = 360; };
                envFrom = [
                  { configMapRef.name = self.coreConfigMap.out.name; }
                  { secretRef.name = self.coreSecret.out.name; }
                ];
                env = [
                  { name = "CORE_SECRET"; valueFrom.secretKeyRef = { name = self.coreSecret.out.name; key = "secret"; }; }
                  { name = "JOBSERVICE_SECRET"; valueFrom.secretKeyRef = { name = self.jobserviceSecret.out.name; key = "JOBSERVICE_SECRET"; }; }
                ]
                ++ lib.optionals (config.database.existingSecret != null) [
                  { name = "POSTGRESQL_PASSWORD"; valueFrom.secretKeyRef = { name = config.database.existingSecret; key = "password"; }; }
                ];
                ports = [ (kix.port "http" 8080) ];
                resources = { requests = { cpu = "20m"; memory = "128Mi"; }; limits = { cpu = "1"; memory = "256Mi"; }; };
                securityContext = containerSecurityContext;
              }
            ];
          };
        };
      }
      |> kix.withMounts [
        self.coreConfigMount
        (kix.mount.emptyDir { name = "ca-download"; mountPath = "/etc/core/ca"; })
        self.coreSecretKeyMount
        (kix.mount.secret self.coreSecret { name = "token-service-private-key"; mountPath = "/etc/core/private_key.pem"; subPath = "tls.key"; })
        (kix.mount.emptyDir { name = "psc"; mountPath = "/etc/core/token"; })
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

    portalService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-portal";
      spec = {
        type = "ClusterIP";
        selector = selectorLabels // { component = "portal"; };
        ports = [ { port = 80; targetPort = 8080; protocol = "TCP"; } ];
      };
      outputs.port = "80";
    };

    portalDeployment =
      {
        name = "${name}-portal";
        spec = {
          replicas = config.portal.replicas;
          revisionHistoryLimit = 5;
          selector.matchLabels = selectorLabels // { component = "portal"; };
          template.spec = harborPodDefaults // {
            containers = [
              {
                name = "portal";
                image = "${config.portal.image.repository}:${config.portal.image.tag}";
                imagePullPolicy = "IfNotPresent";
                ports = [ (kix.port "http" 8080) ];
                livenessProbe = portalProbe // { initialDelaySeconds = 300; };
                readinessProbe = portalProbe // { initialDelaySeconds = 1; };
                securityContext = containerSecurityContext;
              }
            ];
          };
        };
      }
      |> kix.withMounts [
        (kix.mount.configMap self.portalConfigMap { name = "portal-config"; mountPath = "/etc/nginx/nginx.conf"; subPath = "nginx.conf"; })
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
      spec = {
        type = "ClusterIP";
        selector = selectorLabels // { component = "registry"; };
        ports = [
          { name = "http-registry"; port = 5000; targetPort = 5000; protocol = "TCP"; }
          { name = "http-controller"; port = 8080; targetPort = 8080; protocol = "TCP"; }
        ]
        ++ lib.optionals config.metrics.enabled [
          { name = "http-metrics"; port = config.metrics.port; targetPort = config.metrics.port; protocol = "TCP"; }
        ];
      };
    };

    # Registry has 2 containers sharing volumes — manual volumeMounts,
    # but kix.withMounts for the shared volume list via targetContainer.
    registryDeployment =
      {
        name = "${name}-registry";
        spec = {
          replicas = config.registry.replicas;
          revisionHistoryLimit = 5;
          strategy.type = "Recreate";
          selector.matchLabels = selectorLabels // { component = "registry"; };
          template.spec = harborPodDefaults // {
            securityContext = harborPodDefaults.securityContext // { fsGroupChangePolicy = "OnRootMismatch"; };
            containers = [
              {
                name = "registry";
                image = "goharbor/registry-photon:${config.registry.image.tag}";
                imagePullPolicy = "IfNotPresent";
                ports = [ (kix.port "http-registry" 5000) (kix.port "http-metrics" config.metrics.port) ];
                livenessProbe = registryProbe // { initialDelaySeconds = 300; };
                readinessProbe = registryProbe // { initialDelaySeconds = 1; };
                envFrom = [ { secretRef.name = self.registrySecret.out.name; } ];
                volumeMounts = [
                  { name = "registry-config"; mountPath = "/etc/registry/config.yml"; subPath = "config.yml"; }
                  { name = "registry-htpasswd"; mountPath = "/etc/registry/passwd"; subPath = "passwd"; }
                  { name = "registry-data"; mountPath = "/storage"; }
                ];
                securityContext = containerSecurityContext;
              }
              {
                name = "registryctl";
                image = "${config.registry.image.repository}:${config.registry.image.tag}";
                imagePullPolicy = "IfNotPresent";
                ports = [ (kix.port "http-controller" 8080) ];
                livenessProbe = registryCtlProbe // { initialDelaySeconds = 300; };
                readinessProbe = registryCtlProbe // { initialDelaySeconds = 1; };
                env = [
                  { name = "CORE_SECRET"; valueFrom.secretKeyRef = { name = self.coreSecret.out.name; key = "secret"; }; }
                  { name = "JOBSERVICE_SECRET"; valueFrom.secretKeyRef = { name = self.jobserviceSecret.out.name; key = "JOBSERVICE_SECRET"; }; }
                ];
                envFrom = [
                  { configMapRef.name = self.registryCtlConfigMap.out.name; }
                  { secretRef.name = self.registrySecret.out.name; }
                  { secretRef.name = self.registryCtlSecret.out.name; }
                ];
                volumeMounts = [
                  { name = "registry-config"; mountPath = "/etc/registry/config.yml"; subPath = "config.yml"; }
                  { name = "registry-config"; mountPath = "/etc/registryctl/config.yml"; subPath = "ctl-config.yml"; }
                  { name = "registry-data"; mountPath = "/storage"; }
                ];
                securityContext = containerSecurityContext;
              }
            ];
            volumes = [
              { name = "registry-config"; configMap.name = self.registryConfigMap.out.name; }
              { name = "registry-data"; persistentVolumeClaim.claimName = self.registryPVC.out.name; }
              { name = "registry-htpasswd"; secret = { secretName = self.registryHtpasswdSecret.out.name; items = [{ key = "REGISTRY_HTPASSWD"; path = "passwd"; }]; }; }
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

    registryCtlSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-registryctl";
      extra = { type = "Opaque"; stringData = { }; };
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
            max_update_hours: 24
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

    jobserviceSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-jobservice";
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
      spec = {
        type = "ClusterIP";
        selector = selectorLabels // { component = "jobservice"; };
        ports = [
          { name = "http-jobservice"; port = 80; targetPort = 8080; protocol = "TCP"; }
        ]
        ++ lib.optionals config.metrics.enabled [
          { name = "http-metrics"; port = config.metrics.port; targetPort = config.metrics.port; protocol = "TCP"; }
        ];
      };
    };

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
          selector.matchLabels = selectorLabels // { component = "jobservice"; };
          template.spec = harborPodDefaults // {
            containers = [
              {
                name = "jobservice";
                image = "${config.jobservice.image.repository}:${config.jobservice.image.tag}";
                imagePullPolicy = "IfNotPresent";
                ports = [ (kix.port "http" 8080) ];
                livenessProbe = jobserviceProbe // { initialDelaySeconds = 300; };
                readinessProbe = jobserviceProbe // { initialDelaySeconds = 20; };
                env = [
                  { name = "CORE_SECRET"; valueFrom.secretKeyRef = { name = self.coreSecret.out.name; key = "secret"; }; }
                ];
                envFrom = [
                  { configMapRef.name = self.jobserviceEnvConfigMap.out.name; }
                  { secretRef.name = self.jobserviceSecret.out.name; }
                ];
                resources = { requests = { cpu = "20m"; memory = "128Mi"; }; limits = { cpu = "2"; memory = "1Gi"; }; };
                securityContext = containerSecurityContext;
              }
            ];
          };
        };
      }
      |> kix.withMounts [
        (kix.mount.configMap self.jobserviceConfigMap { name = "jobservice-config"; mountPath = "/etc/jobservice/config.yml"; subPath = "config.yml"; })
        (kix.mount.pvc self.jobservicePVC { name = "job-logs"; mountPath = "/var/log/jobs"; })
      ]
      |> scope.mkDeployment;

    # ============================================================
    # Exporter -- Prometheus metrics exporter
    # ============================================================

    exporterSecret = scope.mkResource {
      apiVersion = "v1";
      kind = "Secret";
      name = "${name}-exporter";
      extra = { type = "Opaque"; stringData = { }; };
    };

    # ============================================================
    # Ingress
    # ============================================================

    ingress =
      if config.ingress.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          name = "${name}-ingress";
          annotations = {
            "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
          };
          spec = {
            ingressClassName =
              if ingressNginx != null then ingressNginx.out.ingressClassName
              else config.ingress.className or "public-v2";
            rules = [
              {
                host = config.ingress.host;
                http.paths = [
                  { path = "/api/"; pathType = "Prefix"; backend.service = { name = self.coreService.out.name; port.number = 80; }; }
                  { path = "/service/"; pathType = "Prefix"; backend.service = { name = self.coreService.out.name; port.number = 80; }; }
                  { path = "/v2/"; pathType = "Prefix"; backend.service = { name = self.coreService.out.name; port.number = 80; }; }
                  { path = "/c/"; pathType = "Prefix"; backend.service = { name = self.coreService.out.name; port.number = 80; }; }
                  { path = "/"; pathType = "Prefix"; backend.service = { name = self.portalService.out.name; port.number = 80; }; }
                ];
              }
            ];
          }
          // lib.optionalAttrs (config.ingress.tls.enabled or false) {
            tls = [
              { hosts = [ config.ingress.host ]; secretName = config.ingress.tls.secretName; }
            ];
          };
        }
        |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
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
      ++ lib.optional config.ingress.enabled self.ingress;
    };
  };
}
