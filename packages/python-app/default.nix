# python-app kix package — generic Django/Next.js application platform.
#
# Used by Shopfront (3 environments) and Ledgerly. Supports backend
# (Django/Gunicorn), frontend (Next.js), caddy (LB/WAF), queue workers,
# cron workers, custom processes, in-cluster Redis, ingress with
# cert-manager TLS, ConfigMap environment, secrets, and migration hooks.
#
# Dependencies (postgres, valkey) are optional — resolved via DNS-like DI.
#
# main = backend Service (or caddy Service if caddy enabled).

{
  scope,
  config,
  lib,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    # Naming overrides
    releaseName = null; # if set, used as prefix for resource names instead of instance name
    componentName = "backend"; # component suffix for deployment/service names (e.g. "web" or "backend")

    # Backend (Django/Gunicorn)
    backend = {
      enabled = true;
      image = {
        repository = "";
        tag = "latest";
        pullPolicy = "IfNotPresent";
      };
      replicaCount = 1;
      gunicornWorkers = 4;
      port = 8080;
      containerName = null; # if set, overrides the container name (default: componentName)
      servicePort = null; # if set, the Service exposes this port (targetPort = backend.port); null means use backend.port
      command = null;
      args = null;
      resources = {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
      hpa = {
        enabled = false;
        minReplicas = 1;
        maxReplicas = 10;
        targetCPU = 80;
      };
      probes = {
        enabled = true;
        type = "httpGet"; # "httpGet" or "exec"
        path = "/healthz";
        port = null; # null means use backend.port; set to a different port for separate health endpoint
        execCommand = null; # command list for exec probes
        timeoutSeconds = 20;
        readinessTimeoutSeconds = null; # if set, overrides timeoutSeconds for readiness probe
        initialDelaySeconds = 5;
      };
      extraPorts = [ ]; # additional container ports beyond the main http port
      secrets = [ ];
      strategy = {
        maxSurge = null; # null means use top-level cfg.maxSurge
        maxUnavailable = null; # null means omit (k8s default: 25%)
      };
      initContainers = [ ]; # list of init container specs
      topologySpreadConstraints = [ ]; # list of topology spread constraint specs
    };

    # Frontend (Next.js)
    frontend = {
      enabled = false;
      image = {
        repository = "";
        tag = "latest";
        pullPolicy = "IfNotPresent";
      };
      replicaCount = 1;
      port = 3000;
      command = null;
      args = null;
      resources = {
        requests = {
          cpu = "10m";
          memory = "128Mi";
        };
        limits = {
          cpu = "500m";
          memory = "512Mi";
        };
      };
      probes = {
        enabled = true;
        path = "/";
        timeoutSeconds = 5;
        initialDelaySeconds = 5;
      };
      secrets = [ ];
    };

    # Caddy (Load Balancer/WAF)
    caddy = {
      enabled = false;
      image = {
        repository = "";
        tag = "latest";
        pullPolicy = "IfNotPresent";
      };
      replicaCount = 1;
      port = 8080;
      resources = { };
      hpa = {
        enabled = false;
        minReplicas = 1;
        maxReplicas = 10;
        targetCPU = 80;
      };
    };

    # Workers
    cronWorkers = { };
    queueWorkers = { };
    customProcesses = { };

    # Redis
    redis = {
      enabled = false;
      image = {
        repository = "redis";
        tag = "7";
      };
      resources = {
        requests = {
          cpu = "10m";
          memory = "50Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      };
    };

    # Ingress
    ingress = {
      enabled = false;
      className = "public-v2";
      hosts = [ ];
      tls = [ ];
      annotations = { };
      clusterIssuer = "letsencrypt-lithus-production";
    };

    # Hooks
    hooks = {
      migrate = {
        enabled = false;
        command = [ ];
      };
    };

    # Environment
    environment = "production";
    env = { };
    useConfigMap = true; # set to false to skip configmap in envFrom
    frontendEnv = { };
    secretEnv = { };
    secretFiles = { };

    # ServiceAccount
    serviceAccount = {
      enabled = false;
      name = null; # null means use releaseName or name
    };

    # PodDisruptionBudget
    pdb = {
      enabled = false;
      minAvailable = null; # e.g. "50%" or 1
      maxUnavailable = null;
    };

    # Label overrides
    appName = null; # if set, used for app.kubernetes.io/name labels (defaults to instance name)
    selectorLabels = null; # if set, used as selector matchLabels instead of default
    extraServiceLabels = { }; # extra labels to add to services

    # Deployment strategy shortcut
    maxSurge = "100%"; # top-level shortcut applied to backend and worker strategies

    # Priority
    priorityClassName = null;
  };

  # ── Derived naming ───────────────────────────────────────────
  rName = if cfg.releaseName != null then cfg.releaseName else name;
  compName = cfg.componentName;
  containerName = if cfg.backend.containerName != null then cfg.backend.containerName else compName;
  servicePort = if cfg.backend.servicePort != null then cfg.backend.servicePort else cfg.backend.port;
  probePort =
    if cfg.backend.probes.port != null then cfg.backend.probes.port else cfg.backend.port;
  appLabel = if cfg.appName != null then cfg.appName else name;

  # ── Labels ──────────────────────────────────────────────────────
  commonLabels = {
    "app.kubernetes.io/name" = appLabel;
    "app.kubernetes.io/part-of" = appLabel;
  };

  componentLabels =
    component:
    commonLabels
    // {
      "app.kubernetes.io/component" = component;
    };

  selectorLabels =
    component:
    if cfg.selectorLabels != null then
      cfg.selectorLabels
    else
      {
        "app.kubernetes.io/name" = appLabel;
        "app.kubernetes.io/component" = component;
      };

  # ── Dependency wiring ───────────────────────────────────────────
  depEnv =
    { }
    // lib.optionalAttrs (postgres != null) {
      DATABASE_HOST = postgres.fqdn;
    }
    // lib.optionalAttrs (valkey != null) {
      VALKEY_HOST = valkey.fqdn;
    };

  # ── Secret file volumes + mounts ────────────────────────────────
  secretFileNames = builtins.attrNames cfg.secretFiles;

  secretVolumes = map (n: {
    name = "secret-${n}";
    secret = {
      secretName = "${name}-secret-files";
      items = [
        {
          key = n;
          path = n;
        }
      ];
    };
  }) secretFileNames;

  secretVolumeMounts = map (n: {
    name = "secret-${n}";
    mountPath = "/secrets/${n}";
    subPath = n;
    readOnly = true;
  }) secretFileNames;

  # ── Common pod spec fragments ───────────────────────────────────
  mkEnvFrom =
    self: configMapName: secretRefs:
    lib.optional cfg.useConfigMap { configMapRef.name = "${configMapName}"; }
    ++ map (s: { secretRef.name = s; }) secretRefs;

  mkPodSpec =
    self:
    {
      containers,
      initContainers ? [ ],
      volumes ? [ ],
    }:
    {
      inherit containers;
      volumes = volumes ++ secretVolumes;
    }
    // lib.optionalAttrs (initContainers != [ ]) {
      inherit initContainers;
    }
    // lib.optionalAttrs (cfg.priorityClassName != null) {
      priorityClassName = cfg.priorityClassName;
    }
    // lib.optionalAttrs cfg.serviceAccount.enabled {
      serviceAccountName =
        if cfg.serviceAccount.name != null then cfg.serviceAccount.name else rName;
    }
    // lib.optionalAttrs (cfg.backend.topologySpreadConstraints != [ ]) {
      topologySpreadConstraints = cfg.backend.topologySpreadConstraints;
    };

  # ── Probe builders ────────────────────────────────────────────
  mkLivenessProbe =
    if cfg.backend.probes.type == "exec" then
      {
        exec.command = cfg.backend.probes.execCommand;
        timeoutSeconds = cfg.backend.probes.timeoutSeconds;
        initialDelaySeconds = cfg.backend.probes.initialDelaySeconds;
        periodSeconds = 10;
        failureThreshold = 3;
      }
    else
      {
        httpGet = {
          path = cfg.backend.probes.path;
          port = probePort;
        };
        timeoutSeconds = cfg.backend.probes.timeoutSeconds;
        periodSeconds = 10;
        failureThreshold = 3;
      };

  mkReadinessProbe =
    let
      readinessTimeout =
        if cfg.backend.probes.readinessTimeoutSeconds != null then
          cfg.backend.probes.readinessTimeoutSeconds
        else
          cfg.backend.probes.timeoutSeconds;
    in
    if cfg.backend.probes.type == "exec" then
      {
        exec.command = cfg.backend.probes.execCommand;
        timeoutSeconds = readinessTimeout;
        initialDelaySeconds = cfg.backend.probes.initialDelaySeconds;
        periodSeconds = 10;
        failureThreshold = 3;
      }
    else
      {
        httpGet = {
          path = cfg.backend.probes.path;
          port = probePort;
        };
        initialDelaySeconds = cfg.backend.probes.initialDelaySeconds;
        timeoutSeconds = readinessTimeout;
        periodSeconds = 10;
        failureThreshold = 3;
      };

  # ── Backend container ───────────────────────────────────────────
  mkBackendContainer =
    self:
    {
      name = containerName;
      image = "${cfg.backend.image.repository}:${cfg.backend.image.tag}";
      imagePullPolicy = cfg.backend.image.pullPolicy;
      envFrom = mkEnvFrom self self.configmap cfg.backend.secrets;
      ports = [
        {
          name = "http";
          containerPort = cfg.backend.port;
          protocol = "TCP";
        }
      ] ++ cfg.backend.extraPorts;
      volumeMounts = secretVolumeMounts;
      resources = cfg.backend.resources;
    }
    // lib.optionalAttrs (cfg.backend.command != null) {
      command = cfg.backend.command;
    }
    // lib.optionalAttrs (cfg.backend.args != null) {
      args = cfg.backend.args;
    }
    // lib.optionalAttrs cfg.backend.probes.enabled {
      livenessProbe = mkLivenessProbe;
      readinessProbe = mkReadinessProbe;
    };

  # ── Frontend container ──────────────────────────────────────────
  mkFrontendContainer =
    self:
    {
      name = "frontend";
      image = "${cfg.frontend.image.repository}:${cfg.frontend.image.tag}";
      imagePullPolicy = cfg.frontend.image.pullPolicy;
      envFrom = [
        { configMapRef.name = "${self.frontendConfigmap}"; }
      ]
      ++ map (s: { secretRef.name = s; }) cfg.frontend.secrets;
      ports = [
        {
          name = "http";
          containerPort = cfg.frontend.port;
          protocol = "TCP";
        }
      ];
      resources = cfg.frontend.resources;
    }
    // lib.optionalAttrs (cfg.frontend.command != null) {
      command = cfg.frontend.command;
    }
    // lib.optionalAttrs (cfg.frontend.args != null) {
      args = cfg.frontend.args;
    }
    // lib.optionalAttrs cfg.frontend.probes.enabled {
      livenessProbe = {
        httpGet = {
          path = cfg.frontend.probes.path;
          port = cfg.frontend.port;
        };
        timeoutSeconds = cfg.frontend.probes.timeoutSeconds;
        initialDelaySeconds = cfg.frontend.probes.initialDelaySeconds;
        periodSeconds = 10;
        failureThreshold = 3;
      };
      readinessProbe = {
        httpGet = {
          path = cfg.frontend.probes.path;
          port = cfg.frontend.port;
        };
        timeoutSeconds = cfg.frontend.probes.timeoutSeconds;
        initialDelaySeconds = cfg.frontend.probes.initialDelaySeconds;
        periodSeconds = 10;
        failureThreshold = 3;
      };
    };

  # ── Worker container builder ────────────────────────────────────
  mkWorkerContainer =
    self:
    {
      workerName,
      command,
      args ? null,
      resources ? { },
    }:
    {
      name = workerName;
      image = "${cfg.backend.image.repository}:${cfg.backend.image.tag}";
      imagePullPolicy = cfg.backend.image.pullPolicy;
      inherit command;
      envFrom = mkEnvFrom self self.configmap cfg.backend.secrets;
      volumeMounts = secretVolumeMounts;
      inherit resources;
    }
    // lib.optionalAttrs (args != null) { inherit args; };

  # ── Worker Deployment builder ───────────────────────────────────
  mkWorkerDeployment =
    self:
    {
      workerName,
      command,
      args ? null,
      replicas ? 1,
      resources ? { },
    }:
    scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-${workerName}";
      labels = componentLabels workerName;
      spec = {
        inherit replicas;
        strategy.rollingUpdate.maxSurge = "100%";
        selector.matchLabels = selectorLabels workerName;
        template = {
          metadata.labels = selectorLabels workerName;
          spec = mkPodSpec self {
            containers = [
              (mkWorkerContainer self {
                inherit
                  workerName
                  command
                  args
                  resources
                  ;
              })
            ];
          };
        };
      };
    };

  # ── Worker HPA builder ──────────────────────────────────────────
  mkWorkerHpa =
    {
      hpaName,
      deployResource,
      hpaCfg,
    }:
    if hpaCfg.enabled or false then
      scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "${name}-${hpaName}";
        labels = componentLabels hpaName;
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${deployResource}";
          };
          minReplicas = hpaCfg.minReplicas or 1;
          maxReplicas = hpaCfg.maxReplicas or 10;
          metrics = [
            {
              type = "Resource";
              resource = {
                name = "cpu";
                target = {
                  type = "Utilization";
                  averageUtilization = hpaCfg.targetCPU or 80;
                };
              };
            }
          ];
        };
      }
    else
      null;

in
self:
let

  # ── Queue worker resources ──────────────────────────────────────
  queueWorkerParts = lib.concatMapAttrs (
    wName: wCfg:
    let
      deployKey = "queueWorker-${wName}";
      hpaKey = "queueWorkerHpa-${wName}";
      deploy = mkWorkerDeployment self {
        workerName = "queue-${wName}";
        command = wCfg.command;
        args = wCfg.args or null;
        replicas = wCfg.replicas or 1;
        resources = wCfg.resources or { };
      };
      hpa = mkWorkerHpa {
        hpaName = "queue-${wName}";
        deployResource = deploy;
        hpaCfg = wCfg.hpa or { enabled = false; };
      };
    in
    { ${deployKey} = deploy; } // lib.optionalAttrs (hpa != null) { ${hpaKey} = hpa; }
  ) cfg.queueWorkers;

  # ── Cron worker resources ───────────────────────────────────────
  cronWorkerParts = lib.concatMapAttrs (wName: wCfg: {
    "cronWorker-${wName}" = mkWorkerDeployment self {
      workerName = "cron-${wName}";
      command = wCfg.command;
      args = wCfg.args or null;
      replicas = wCfg.replicas or 1;
      resources = wCfg.resources or { };
    };
  }) cfg.cronWorkers;

  # ── Custom process resources ────────────────────────────────────
  customProcessParts = lib.concatMapAttrs (pName: pCfg: {
    "customProcess-${pName}" = mkWorkerDeployment self {
      workerName = "custom-${pName}";
      command = pCfg.command;
      args = pCfg.args or null;
      replicas = pCfg.replicas or 1;
      resources = pCfg.resources or { };
    };
  }) cfg.customProcesses;

  # All worker-related resources for main.requires
  allWorkerResources =
    builtins.attrValues queueWorkerParts
    ++ builtins.attrValues cronWorkerParts
    ++ builtins.attrValues customProcessParts;

  # Strategy spec
  strategySpec = {
    rollingUpdate = {
      maxSurge = if cfg.backend.strategy.maxSurge != null then cfg.backend.strategy.maxSurge else cfg.maxSurge;
    }
    // lib.optionalAttrs (cfg.backend.strategy.maxUnavailable != null) {
      maxUnavailable = cfg.backend.strategy.maxUnavailable;
    };
    type = "RollingUpdate";
  };

in
{

  # ── ConfigMap (backend environment) ─────────────────────────────
  configmap =
    if cfg.useConfigMap then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-environment";
        labels = componentLabels "config";
        data = {
          ENVIRONMENT = cfg.environment;
        }
        // depEnv
        // cfg.env;
      }
    else
      null;

  # ── ConfigMap (frontend environment) ────────────────────────────
  frontendConfigmap =
    if cfg.frontend.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-environment-frontend";
        labels = componentLabels "config-frontend";
        data = cfg.frontendEnv;
      }
    else
      null;

  # ── Secret (env vars) ──────────────────────────────────────────
  secret =
    if cfg.secretEnv != { } then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = "${name}-secrets";
        labels = componentLabels "secrets";
        extra = {
          type = "Opaque";
          stringData = cfg.secretEnv;
        };
      }
    else
      null;

  # ── Secret (file mounts) ───────────────────────────────────────
  secretFilesResource =
    if cfg.secretFiles != { } then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = "${name}-secret-files";
        labels = componentLabels "secret-files";
        extra = {
          type = "Opaque";
          stringData = cfg.secretFiles;
        };
      }
    else
      null;

  # ── ServiceAccount ───────────────────────────────────────────────
  serviceAccount =
    if cfg.serviceAccount.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = if cfg.serviceAccount.name != null then cfg.serviceAccount.name else rName;
        labels = componentLabels "serviceaccount";
      }
    else
      null;

  # ── Backend Deployment ──────────────────────────────────────────
  backendDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${rName}-${compName}";
    labels = componentLabels compName;
    spec = {
      replicas = cfg.backend.replicaCount;
      strategy = strategySpec;
      selector.matchLabels = selectorLabels compName;
      template = {
        metadata = {
          labels = selectorLabels compName;
        }
        // lib.optionalAttrs cfg.useConfigMap {
          annotations = {
            "checksum/config" = "\${${self.configmap}}";
          };
        };
        spec = mkPodSpec self {
          containers = [ (mkBackendContainer self) ];
          initContainers = cfg.backend.initContainers;
        };
      };
    };
  };

  # ── Backend Service ─────────────────────────────────────────────
  backendService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${rName}-${compName}-internal";
    labels = componentLabels compName // cfg.extraServiceLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels compName;
      ports = [
        {
          name = "http";
          port = servicePort;
          targetPort = cfg.backend.port;
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      port = toString servicePort;
    };
    requires = [ self.backendDeployment ]
      ++ lib.optional (self.serviceAccount != null) self.serviceAccount;
  };

  # ── Backend HPA ─────────────────────────────────────────────────
  backendHpa =
    if cfg.backend.hpa.enabled then
      scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "${rName}-${compName}";
        labels = componentLabels compName;
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${self.backendDeployment}";
          };
          minReplicas = cfg.backend.hpa.minReplicas;
          maxReplicas = cfg.backend.hpa.maxReplicas;
          metrics = [
            {
              type = "Resource";
              resource = {
                name = "cpu";
                target = {
                  type = "Utilization";
                  averageUtilization = cfg.backend.hpa.targetCPU;
                };
              };
            }
          ];
        };
      }
    else
      null;

  # ── PodDisruptionBudget ──────────────────────────────────────────
  pdb =
    if cfg.pdb.enabled then
      scope.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        name = "${rName}-${compName}";
        labels = componentLabels compName;
        spec = {
          selector.matchLabels = selectorLabels compName;
        }
        // lib.optionalAttrs (cfg.pdb.minAvailable != null) {
          minAvailable = cfg.pdb.minAvailable;
        }
        // lib.optionalAttrs (cfg.pdb.maxUnavailable != null) {
          maxUnavailable = cfg.pdb.maxUnavailable;
        };
      }
    else
      null;

  # ── Frontend Deployment ─────────────────────────────────────────
  frontendDeployment =
    if cfg.frontend.enabled then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-frontend";
        labels = componentLabels "frontend";
        spec = {
          replicas = cfg.frontend.replicaCount;
          strategy.rollingUpdate.maxSurge = "100%";
          selector.matchLabels = selectorLabels "frontend";
          template = {
            metadata = {
              labels = selectorLabels "frontend";
              annotations = {
                "checksum/config" = "\${${self.frontendConfigmap}}";
              };
            };
            spec = mkPodSpec self {
              containers = [ (mkFrontendContainer self) ];
              volumes = [ ];
            };
          };
        };
      }
    else
      null;

  # ── Frontend Service ────────────────────────────────────────────
  frontendService =
    if cfg.frontend.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-frontend";
        labels = componentLabels "frontend";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "frontend";
          ports = [
            {
              name = "http";
              port = cfg.frontend.port;
              targetPort = "http";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = toString cfg.frontend.port;
        };
        requires = [ self.frontendDeployment ];
      }
    else
      null;

  # ── Caddy Deployment ────────────────────────────────────────────
  caddyDeployment =
    if cfg.caddy.enabled then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          replicas = cfg.caddy.replicaCount;
          strategy.rollingUpdate.maxSurge = "100%";
          selector.matchLabels = selectorLabels "caddy";
          template = {
            metadata.labels = selectorLabels "caddy";
            spec = mkPodSpec self {
              containers = [
                {
                  name = "caddy";
                  image = "${cfg.caddy.image.repository}:${cfg.caddy.image.tag}";
                  imagePullPolicy = cfg.caddy.image.pullPolicy;
                  ports = [
                    {
                      name = "http";
                      containerPort = cfg.caddy.port;
                      protocol = "TCP";
                    }
                  ];
                  env = [
                    {
                      name = "BACKEND_HOST";
                      value = "${self.backendService}";
                    }
                    {
                      name = "BACKEND_PORT";
                      value = toString cfg.backend.port;
                    }
                  ]
                  ++ lib.optionals cfg.frontend.enabled [
                    {
                      name = "FRONTEND_HOST";
                      value = "${self.frontendService}";
                    }
                    {
                      name = "FRONTEND_PORT";
                      value = toString cfg.frontend.port;
                    }
                  ];
                  resources = cfg.caddy.resources;
                }
              ];
              volumes = [ ];
            };
          };
        };
      }
    else
      null;

  # ── Caddy Service ───────────────────────────────────────────────
  caddyService =
    if cfg.caddy.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "caddy";
          ports = [
            {
              name = "http";
              port = cfg.caddy.port;
              targetPort = "http";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = toString cfg.caddy.port;
        };
        requires = [ self.caddyDeployment ];
      }
    else
      null;

  # ── Caddy HPA ──────────────────────────────────────────────────
  caddyHpa =
    if cfg.caddy.enabled && cfg.caddy.hpa.enabled then
      scope.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        name = "${name}-caddy";
        labels = componentLabels "caddy";
        spec = {
          scaleTargetRef = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${self.caddyDeployment}";
          };
          minReplicas = cfg.caddy.hpa.minReplicas;
          maxReplicas = cfg.caddy.hpa.maxReplicas;
          metrics = [
            {
              type = "Resource";
              resource = {
                name = "cpu";
                target = {
                  type = "Utilization";
                  averageUtilization = cfg.caddy.hpa.targetCPU;
                };
              };
            }
          ];
        };
      }
    else
      null;

  # ── Redis Deployment ────────────────────────────────────────────
  redisDeployment =
    if cfg.redis.enabled then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-redis";
        labels = componentLabels "redis";
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          selector.matchLabels = selectorLabels "redis";
          template = {
            metadata.labels = selectorLabels "redis";
            spec = {
              containers = [
                {
                  name = "redis";
                  image = "${cfg.redis.image.repository}:${cfg.redis.image.tag}";
                  ports = [
                    {
                      name = "redis";
                      containerPort = 6379;
                      protocol = "TCP";
                    }
                  ];
                  resources = cfg.redis.resources;
                  volumeMounts = [
                    {
                      name = "data";
                      mountPath = "/data";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "data";
                  emptyDir = { };
                }
              ];
            };
          };
        };
      }
    else
      null;

  # ── Redis Service ───────────────────────────────────────────────
  redisService =
    if cfg.redis.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-redis";
        labels = componentLabels "redis";
        spec = {
          type = "ClusterIP";
          selector = selectorLabels "redis";
          ports = [
            {
              name = "redis";
              port = 6379;
              targetPort = "redis";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = "6379";
        };
        requires = [ self.redisDeployment ];
      }
    else
      null;

  # ── Ingress ─────────────────────────────────────────────────────
  ingress =
    if cfg.ingress.enabled then
      let
        resolveServiceName =
          svcName:
          if svcName == "backend" then
            "${self.backendService}"
          else if svcName == "frontend" && cfg.frontend.enabled then
            "${self.frontendService}"
          else if svcName == "caddy" && cfg.caddy.enabled then
            "${self.caddyService}"
          else
            svcName;

        resolveServicePort =
          svcName:
          if svcName == "backend" then
            servicePort
          else if svcName == "frontend" then
            cfg.frontend.port
          else if svcName == "caddy" then
            cfg.caddy.port
          else
            80;

        rules = map (host: {
          host = host.host;
          http.paths = map (pathCfg: {
            path = pathCfg.path;
            pathType = pathCfg.pathType or "Prefix";
            backend.service = {
              name = resolveServiceName pathCfg.service;
              port.number = pathCfg.port or (resolveServicePort pathCfg.service);
            };
          }) host.paths;
        }) cfg.ingress.hosts;

        tlsSpec =
          if cfg.ingress.tls != [ ] then
            cfg.ingress.tls
          else
            let
              hosts = map (h: h.host) cfg.ingress.hosts;
            in
            if hosts != [ ] then
              [
                {
                  secretName = "${rName}-tls";
                  inherit hosts;
                }
              ]
            else
              [ ];
      in
      scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "${rName}-${compName}";
        labels = componentLabels "ingress";
        annotations = {
          "cert-manager.io/cluster-issuer" = cfg.ingress.clusterIssuer;
        }
        // cfg.ingress.annotations;
        spec = {
          ingressClassName = cfg.ingress.className;
          inherit rules;
        }
        // lib.optionalAttrs (tlsSpec != [ ]) {
          tls = tlsSpec;
        };
        requires =
          (if cfg.caddy.enabled then [ self.caddyService ] else [ self.backendService ])
          ++ lib.optional cfg.frontend.enabled self.frontendService;
      }
    else
      null;

  # ── Migration Hook (Job) ────────────────────────────────────────
  migrateJob =
    if cfg.hooks.migrate.enabled then
      scope.mkResource {
        apiVersion = "batch/v1";
        kind = "Job";
        name = "${name}-migrate";
        labels = componentLabels "migrate";
        annotations = {
          "kix.dev/hook" = "pre-deploy";
          "kix.dev/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        };
        spec = {
          activeDeadlineSeconds = 3600;
          backoffLimit = 0;
          ttlSecondsAfterFinished = 28800;
          template = {
            metadata.labels = selectorLabels "migrate";
            spec = {
              restartPolicy = "Never";
              containers = [
                {
                  name = "migrate";
                  image = "${cfg.backend.image.repository}:${cfg.backend.image.tag}";
                  imagePullPolicy = cfg.backend.image.pullPolicy;
                  command = cfg.hooks.migrate.command;
                  envFrom = mkEnvFrom self self.configmap cfg.backend.secrets;
                  volumeMounts = secretVolumeMounts;
                }
              ];
              volumes = secretVolumes;
            };
          };
        };
      }
    else
      null;

  # ── Entry point ─────────────────────────────────────────────────
  main = {
    resource = if cfg.caddy.enabled then self.caddyService else self.backendService;
    requires =
      allWorkerResources
      ++ lib.optional (self.backendHpa != null) self.backendHpa
      ++ lib.optional (self.caddyHpa != null) self.caddyHpa
      ++ lib.optional (self.redisService != null) self.redisService
      ++ lib.optional (self.ingress != null) self.ingress
      ++ lib.optional (self.migrateJob != null) self.migrateJob
      ++ lib.optional (self.secret != null) self.secret
      ++ lib.optional (self.secretFilesResource != null) self.secretFilesResource
      ++ lib.optional (self.frontendService != null) self.frontendService
      ++ lib.optional (self.pdb != null) self.pdb;
  };
}
# Merge dynamic worker parts into the fixpoint so they appear in
# allPartResources (needed for closure computation + registry).
// queueWorkerParts
// cronWorkerParts
// customProcessParts
