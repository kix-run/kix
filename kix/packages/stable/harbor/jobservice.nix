# Harbor jobservice (replication, GC, and retention) and metrics exporter.

{
  self,
  config,
  scope,
  lib,
  kix,
  database,
  redis,
  harborSecrets,
  caBundle ? null,
  prometheus ? null,
  reloader ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    metricsPort
    registryUser
    svc
    ;
  b = c.forBuild {
    inherit
      self
      config
      database
      redis
      harborSecrets
      caBundle
      prometheus
      reloader
      ;
  };
  inherit (b)
    metricsEnabled
    secrets
    ca
    dbCredentials
    valkeySecret
    checksumOf
    reloadOn
    sslmode
    dbLoginEnv
    coreUrl
    tokenServiceUrl
    registryUrl
    registryCtlUrl
    redisUrl
    redisPasswordEnv
    valkeyChecksum
    componentEnv
    componentSelector
    jobserviceSelector
    componentLabels
    containerSecurityContext
    caBundleMount
    tmpMount
    harborPodDefaults
    jobserviceProbe
    exporterProbe
    metricsContainerPort
    metricsServicePort
    ;

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

  # The redis URL arrives as JOB_SERVICE_POOL_REDIS_URL, because it
  # carries the password; jobservice reads JOB_SERVICE_* env over the
  # file. The DB job logger keeps every job's log in the database, so
  # any jobservice pod can serve it.
  jobserviceConfig = lib.filterAttrsRecursive (_: v: v != null) (
    kix.mergeGuarded
      {
        inherit scope;
        option = "jobservice.settings";
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
          "checksum/config" = self.jobserviceConfigMap.out.contentHash;
          "checksum/env" = self.jobserviceEnvConfigMap.out.contentHash;
        }
        // checksumOf "harbor-secrets" secrets
        // checksumOf "ca-bundle" ca
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
                    ++ dbLoginEnv "POSTGRESQL_USERNAME" "POSTGRESQL_PASSWORD"
                    ++ redisPasswordEnv;
                  facts = builtins.attrNames jobserviceEnvData;
                  sslmodeVar = "POSTGRESQL_SSLMODE";
                  vars = {
                    POSTGRESQL_HOST = database.out.host;
                    POSTGRESQL_PORT = database.out.port;
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
    |> reloadOn [
      secrets
      ca
      dbCredentials
      valkeySecret
    ]
    |> scope.mkDeployment;

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
            "checksum/env" = self.exporterEnvConfigMap.out.contentHash;
          }
          // checksumOf "harbor-secrets" secrets
          // checksumOf "ca-bundle" ca
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
                    ++ dbLoginEnv "HARBOR_DATABASE_USERNAME" "HARBOR_DATABASE_PASSWORD"
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
      |> reloadOn [
        secrets
        ca
        dbCredentials
        valkeySecret
      ]
      |> scope.mkDeployment;
}
