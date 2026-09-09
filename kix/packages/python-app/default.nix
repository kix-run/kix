# python-app kix package — generic Django/Next.js application platform.
#
# Used by Shopfront (3 environments) and Ledgerly. Supports backend
# (Django/Gunicorn), frontend (Next.js), caddy (LB/WAF), queue workers,
# cron workers, custom processes, in-cluster Redis, ingress with
# cert-manager TLS, ConfigMap environment, secrets, and migration hooks.
#
# Dependencies:
#   postgres            — optional, database
#   valkey              — optional, cache/queue backend
#   ingressNginx        — optional, auto-creates ingress when present (+ hosts non-empty)
#   clusterIssuer       — optional, auto-enables TLS when present
#
# root = backend Service (or caddy Service if caddy enabled).

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
    version = "1.0.0";
    description = "Generic Django/Next.js application platform";
  };

  options = {
    # Naming overrides
    releaseName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    }; # if set, used as prefix for resource names instead of instance name
    componentName = lib.mkOption {
      type = lib.types.str;
      default = "web";
    }; # component suffix for deployment/service names (e.g. "web" or "backend")

    # Backend (Django/Gunicorn)
    backend = lib.mkOption {
      type = lib.types.anything;
      default = {
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
        env = { }; # direct env vars on the backend container (not via ConfigMap)
        secrets = [ ];
        strategy = {
          maxSurge = null; # null means use top-level config.maxSurge
          maxUnavailable = null; # null means omit (k8s default: 25%)
        };
        initContainers = [ ]; # list of init container specs
        topologySpreadConstraints = [ ]; # list of topology spread constraint specs
      };
    };

    # Frontend (Next.js)
    frontend = lib.mkOption {
      type = lib.types.anything;
      default = {
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
        strategy = {
          maxSurge = null; # null means use top-level config.maxSurge
          maxUnavailable = null; # null means omit
        };
        useConfigMap = true; # set to false to skip configmap envFrom for frontend
      };
    };

    # Caddy (Load Balancer/WAF)
    caddy = lib.mkOption {
      type = lib.types.anything;
      default = {
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
    };

    # Workers
    cronWorkers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    queueWorkers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    customProcesses = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };

    # Redis
    redis = lib.mkOption {
      type = lib.types.anything;
      default = {
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
    };

    # Ingress — gated by ingressNginx DI dep + hosts being non-empty.
    # TLS auto-enabled when clusterIssuer DI dep is present.
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        hosts = [ ];
        tls = [ ];
        autoTls = true; # when true and tls=[], auto-generate TLS from host names; set false to disable
        annotations = { };
      };
    };

    # Hooks
    hooks = lib.mkOption {
      type = lib.types.anything;
      default = {
        migrate = {
          enabled = false;
          command = [ ];
        };
      };
    };

    # Environment
    environment = lib.mkOption {
      type = lib.types.str;
      default = "production";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    useConfigMap = lib.mkOption {
      type = lib.types.bool;
      default = true;
    }; # set to false to skip configmap in envFrom
    frontendEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    secretFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };

    # ServiceAccount
    serviceAccount = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        name = null; # null means use releaseName or name
      };
    };

    # PodDisruptionBudget
    pdb = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        minAvailable = null; # e.g. "50%" or 1
        maxUnavailable = null;
      };
    };

    # Label overrides
    appName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    }; # if set, used for app.kubernetes.io/name labels (defaults to instance name)
    selectorLabels = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    }; # if set, used as selector matchLabels instead of default
    extraServiceLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    }; # extra labels to add to services

    # Deployment strategy shortcut
    maxSurge = lib.mkOption {
      type = lib.types.str;
      default = "100%";
    }; # top-level shortcut applied to backend and worker strategies

    # Priority
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      postgres ? null,
      valkey ? null,
      ingressNginx ? null,
      clusterIssuer ? null,
    }:
    let

      # ── Derived naming ───────────────────────────────────────────
      rName = if config.releaseName != null then config.releaseName else name;
      compName = config.componentName;
      containerName =
        if config.backend.containerName != null then config.backend.containerName else compName;
      servicePort =
        if config.backend.servicePort != null then config.backend.servicePort else config.backend.port;
      probePort =
        if config.backend.probes.port != null then config.backend.probes.port else config.backend.port;
      appLabel = if config.appName != null then config.appName else name;

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
        if config.selectorLabels != null then
          config.selectorLabels
        else
          {
            app = component;
            "app.kubernetes.io/instance" = name;
            "app.kubernetes.io/name" = appLabel;
          };

      # ── DI-driven ingress ──────────────────────────────────────────
      hasIngress = ingressNginx != null && config.ingress.hosts != [ ];
      hasTls = hasIngress && clusterIssuer != null;

      # ── Dependency wiring ───────────────────────────────────────────
      depEnv =
        { }
        // lib.optionalAttrs (postgres != null) {
          DATABASE_HOST = postgres.out.fqdn;
        }
        // lib.optionalAttrs (valkey != null) {
          VALKEY_HOST = valkey.out.fqdn;
        };

      # ── Secret file volumes + mounts ────────────────────────────────
      secretFileNames = builtins.attrNames config.secretFiles;

      # secretVolumes uses self.secretFilesResource.out.name (DI-tracked) rather than
      # a raw string. The map body only evaluates when secretFileNames is non-empty,
      # which implies self.secretFilesResource != null (both gated on secretFiles != {}).
      secretVolumes = map (n: {
        name = "secret-${n}";
        secret = {
          secretName = self.secretFilesResource.out.name;
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
      # secretNames: list of externally-managed secret names (strings).
      # Each is wrapped in mkSecretRef to create a DI-tracked store path,
      # satisfying the checkSecretRefs invariant in mkWorkload.
      mkEnvFrom =
        self: configMapName: secretNames:
        lib.optional config.useConfigMap { configMapRef.name = configMapName.out.name; }
        ++ map (
          sName:
          (scope.mkSecretRef {
            name = sName;
            keys = [ ];
          }).out.envFrom
        ) secretNames;

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
        // lib.optionalAttrs (config.priorityClassName != null) {
          priorityClassName = config.priorityClassName;
        }
        // lib.optionalAttrs config.serviceAccount.enabled {
          serviceAccountName = kix.untrackedRef (
            if config.serviceAccount.name != null then config.serviceAccount.name else rName
          );
        };

      # ── Probe builders ────────────────────────────────────────────
      mkLivenessProbe =
        if config.backend.probes.type == "exec" then
          {
            exec.command = config.backend.probes.execCommand;
            timeoutSeconds = config.backend.probes.timeoutSeconds;
            initialDelaySeconds = config.backend.probes.initialDelaySeconds;
            periodSeconds = 10;
            failureThreshold = 3;
          }
        else
          {
            httpGet = {
              path = config.backend.probes.path;
              port = probePort;
            };
            initialDelaySeconds = config.backend.probes.initialDelaySeconds;
            timeoutSeconds = config.backend.probes.timeoutSeconds;
            periodSeconds = 10;
            failureThreshold = 3;
          };

      mkReadinessProbe =
        let
          readinessTimeout =
            if config.backend.probes.readinessTimeoutSeconds != null then
              config.backend.probes.readinessTimeoutSeconds
            else
              config.backend.probes.timeoutSeconds;
        in
        if config.backend.probes.type == "exec" then
          {
            exec.command = config.backend.probes.execCommand;
            timeoutSeconds = readinessTimeout;
            initialDelaySeconds = config.backend.probes.initialDelaySeconds;
            periodSeconds = 10;
            failureThreshold = 3;
          }
        else
          {
            httpGet = {
              path = config.backend.probes.path;
              port = probePort;
            };
            initialDelaySeconds = config.backend.probes.initialDelaySeconds;
            timeoutSeconds = readinessTimeout;
            periodSeconds = 10;
            failureThreshold = 3;
          };

      # ── Backend container ───────────────────────────────────────────
      mkBackendContainer =
        self:
        {
          name = containerName;
          image = "${config.backend.image.repository}:${config.backend.image.tag}";
          imagePullPolicy = config.backend.image.pullPolicy;
          envFrom = mkEnvFrom self self.configmap config.backend.secrets;
          ports = [
            (kix.port "http" config.backend.port)
          ]
          ++ config.backend.extraPorts;
          volumeMounts = secretVolumeMounts;
          resources = config.backend.resources;
        }
        // lib.optionalAttrs (config.backend.command != null) {
          command = config.backend.command;
        }
        // lib.optionalAttrs (config.backend.args != null) {
          args = config.backend.args;
        }
        // lib.optionalAttrs config.backend.probes.enabled {
          livenessProbe = mkLivenessProbe;
          readinessProbe = mkReadinessProbe;
        }
        // lib.optionalAttrs (config.backend.env != { }) {
          env = kix.mkEnvVars config.backend.env;
        };

      # ── Frontend container ──────────────────────────────────────────
      mkFrontendContainer =
        self:
        {
          name = "frontend";
          image = "${config.frontend.image.repository}:${config.frontend.image.tag}";
          imagePullPolicy = config.frontend.image.pullPolicy;
          envFrom =
            lib.optional config.frontend.useConfigMap { configMapRef.name = self.frontendConfigmap.out.name; }
            ++ map (
              sName:
              (scope.mkSecretRef {
                name = sName;
                keys = [ ];
              }).out.envFrom
            ) config.frontend.secrets;
          ports = [
            (kix.port "http" config.frontend.port)
          ];
          resources = config.frontend.resources;
        }
        // lib.optionalAttrs (config.frontend.command != null) {
          command = config.frontend.command;
        }
        // lib.optionalAttrs (config.frontend.args != null) {
          args = config.frontend.args;
        }
        // lib.optionalAttrs config.frontend.probes.enabled {
          livenessProbe = {
            httpGet = {
              path = config.frontend.probes.path;
              port = config.frontend.port;
            };
            timeoutSeconds = config.frontend.probes.timeoutSeconds;
            initialDelaySeconds = config.frontend.probes.initialDelaySeconds;
            periodSeconds = 10;
            failureThreshold = 3;
          };
          readinessProbe = {
            httpGet = {
              path = config.frontend.probes.path;
              port = config.frontend.port;
            };
            timeoutSeconds = config.frontend.probes.timeoutSeconds;
            initialDelaySeconds = config.frontend.probes.initialDelaySeconds;
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
          image ? null,
          lifecycle ? null,
          env ? null,
          rawEnv ? [ ],
          secrets ? null,
          ports ? null,
          probes ? null,
        }:
        {
          name = workerName;
          image =
            if image != null then image else "${config.backend.image.repository}:${config.backend.image.tag}";
          imagePullPolicy = config.backend.image.pullPolicy;
          envFrom = mkEnvFrom self self.configmap (
            if secrets != null then secrets else config.backend.secrets
          );
          volumeMounts = secretVolumeMounts;
          inherit resources;
        }
        // lib.optionalAttrs (command != null) { inherit command; }
        // lib.optionalAttrs (args != null) { inherit args; }
        // lib.optionalAttrs (lifecycle != null) { inherit lifecycle; }
        // lib.optionalAttrs (env != null || rawEnv != [ ]) {
          env = (if env != null then kix.mkEnvVars env else [ ]) ++ rawEnv;
        }
        // lib.optionalAttrs (ports != null) {
          ports = map (p: kix.port p.name p.containerPort) ports;
        }
        // lib.optionalAttrs (probes != null) {
          livenessProbe =
            probes.livenessProbe or {
              httpGet = {
                path = probes.path;
                port = probes.port or (builtins.head ports).containerPort;
              };
              initialDelaySeconds = probes.initialDelaySeconds or 5;
              periodSeconds = probes.periodSeconds or 10;
              failureThreshold = probes.failureThreshold or 3;
              timeoutSeconds = probes.timeoutSeconds or 1;
            };
          readinessProbe =
            probes.readinessProbe or {
              httpGet = {
                path = probes.path;
                port = probes.port or (builtins.head ports).containerPort;
              };
              initialDelaySeconds = probes.initialDelaySeconds or 5;
              periodSeconds = probes.periodSeconds or 10;
              failureThreshold = probes.failureThreshold or 3;
              timeoutSeconds = probes.timeoutSeconds or 1;
            };
        };

      # ── Worker Deployment builder ───────────────────────────────────
      mkWorkerDeployment =
        self:
        {
          workerName,
          command,
          args ? null,
          replicas ? 1,
          resources ? { },
          strategy ? null,
          image ? null,
          lifecycle ? null,
          env ? null,
          rawEnv ? [ ],
          secrets ? null,
          ports ? null,
          probes ? null,
        }:
        let
          deployStrategy = if strategy != null then strategy else { rollingUpdate.maxSurge = "100%"; };
        in
        {
          name = "${name}-${workerName}";
          labels = componentLabels workerName;
          spec = {
            inherit replicas;
            strategy = deployStrategy;
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
                      image
                      lifecycle
                      env
                      rawEnv
                      secrets
                      ports
                      probes
                      ;
                  })
                ];
              };
            };
          };
        }
        |> scope.mkDeployment;

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
                name = deployResource.out.name;
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
            }
            // lib.optionalAttrs (hpaCfg ? behavior) {
              behavior = hpaCfg.behavior;
            };
          }
        else
          null;

      # ── Queue worker resources ──────────────────────────────────────
      queueWorkerParts = lib.concatMapAttrs (
        wName: wCfg:
        let
          wn = wCfg.workerName or "queue-${wName}";
          deployKey = "queueWorker-${wName}";
          hpaKey = "queueWorkerHpa-${wName}";
          deploy = mkWorkerDeployment self {
            workerName = wn;
            command = wCfg.command;
            args = wCfg.args or null;
            replicas = wCfg.replicas or 1;
            resources = wCfg.resources or { };
            strategy = wCfg.strategy or null;
            image = wCfg.image or null;
            lifecycle = wCfg.lifecycle or null;
            env = wCfg.env or null;
            rawEnv = wCfg.rawEnv or [ ];
            secrets = wCfg.secrets or null;
            ports = wCfg.ports or null;
            probes = wCfg.probes or null;
          };
          hpa = mkWorkerHpa {
            hpaName = wn;
            deployResource = deploy;
            hpaCfg = wCfg.hpa or { enabled = false; };
          };
        in
        { ${deployKey} = deploy; } // lib.optionalAttrs (hpa != null) { ${hpaKey} = hpa; }
      ) config.queueWorkers;

      # ── Cron worker resources ───────────────────────────────────────
      cronWorkerParts = lib.concatMapAttrs (wName: wCfg: {
        "cronWorker-${wName}" = mkWorkerDeployment self {
          workerName = wCfg.workerName or "cron-${wName}";
          command = wCfg.command;
          args = wCfg.args or null;
          replicas = wCfg.replicas or 1;
          resources = wCfg.resources or { };
          strategy = wCfg.strategy or null;
          image = wCfg.image or null;
          lifecycle = wCfg.lifecycle or null;
          env = wCfg.env or null;
          rawEnv = wCfg.rawEnv or [ ];
          secrets = wCfg.secrets or null;
          ports = wCfg.ports or null;
          probes = wCfg.probes or null;
        };
      }) config.cronWorkers;

      # ── Custom process resources ────────────────────────────────────
      customProcessParts = lib.concatMapAttrs (
        pName: pCfg:
        let
          wn = pCfg.workerName or "custom-${pName}";
          deployKey = "customProcess-${pName}";
          deploy = mkWorkerDeployment self {
            workerName = wn;
            command = pCfg.command;
            args = pCfg.args or null;
            replicas = pCfg.replicas or 1;
            resources = pCfg.resources or { };
            strategy = pCfg.strategy or null;
            image = pCfg.image or null;
            lifecycle = pCfg.lifecycle or null;
            env = pCfg.env or null;
            rawEnv = pCfg.rawEnv or [ ];
            secrets = pCfg.secrets or null;
            ports = pCfg.ports or null;
            probes = pCfg.probes or null;
          };
          serviceKey = "customProcessService-${pName}";
          containerPort = if pCfg ? ports then (builtins.head pCfg.ports).containerPort else null;
          hasService = (pCfg ? servicePort) || containerPort != null;
          svcPort = pCfg.servicePort or 80;
          svcTargetPort = if containerPort != null then containerPort else svcPort;
          service =
            if hasService then
              scope.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = "${name}-${wn}-internal";
                labels = componentLabels wn;
                spec = {
                  type = "ClusterIP";
                  selector = selectorLabels wn;
                  ports = [
                    {
                      name = "http";
                      port = svcPort;
                      targetPort = svcTargetPort;
                      protocol = "TCP";
                    }
                  ];
                };
                outputs = {
                  port = toString svcPort;
                };
                requires = [ deploy ];
              }
            else
              null;
          hpaKey = "customProcessHpa-${pName}";
          hpa = mkWorkerHpa {
            hpaName = wn;
            deployResource = deploy;
            hpaCfg = pCfg.hpa or { enabled = false; };
          };
        in
        {
          ${deployKey} = deploy;
        }
        // lib.optionalAttrs (service != null) { ${serviceKey} = service; }
        // lib.optionalAttrs (hpa != null) { ${hpaKey} = hpa; }
      ) config.customProcesses;

      # All worker-related resources for root.requires
      allWorkerResources =
        builtins.attrValues queueWorkerParts
        ++ builtins.attrValues cronWorkerParts
        ++ builtins.attrValues customProcessParts;

      # Strategy spec
      strategySpec = {
        rollingUpdate = {
          maxSurge =
            if config.backend.strategy.maxSurge != null then
              config.backend.strategy.maxSurge
            else
              config.maxSurge;
        }
        // lib.optionalAttrs (config.backend.strategy.maxUnavailable != null) {
          maxUnavailable = config.backend.strategy.maxUnavailable;
        };
        type = "RollingUpdate";
      };

    in
    {

      # ── ConfigMap (backend environment) ─────────────────────────────
      configmap =
        if config.useConfigMap then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-environment";
            labels = componentLabels "config";
            data = {
              ENVIRONMENT = config.environment;
            }
            // depEnv
            // config.env;
          }
        else
          null;

      # ── ConfigMap (frontend environment) ────────────────────────────
      frontendConfigmap =
        if config.frontend.enabled && config.frontend.useConfigMap then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-environment-frontend";
            labels = componentLabels "config-frontend";
            data = config.frontendEnv;
          }
        else
          null;

      # ── Secret (env vars) ──────────────────────────────────────────
      secret =
        if config.secretEnv != { } then
          scope.mkSecret {
            name = "${name}-secrets";
            labels = componentLabels "secrets";
            stringData = config.secretEnv;
          }
        else
          null;

      # ── Secret (file mounts) ───────────────────────────────────────
      secretFilesResource =
        if config.secretFiles != { } then
          scope.mkSecret {
            name = "${name}-secret-files";
            labels = componentLabels "secret-files";
            stringData = config.secretFiles;
          }
        else
          null;

      # ── ServiceAccount ───────────────────────────────────────────────
      serviceAccount =
        if config.serviceAccount.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = if config.serviceAccount.name != null then config.serviceAccount.name else rName;
            labels = componentLabels "serviceaccount";
          }
        else
          null;

      # ── Backend Deployment ──────────────────────────────────────────
      backendDeployment =
        {
          name = "${rName}-${compName}";
          labels = componentLabels compName;
          spec = {
            replicas = config.backend.replicaCount;
            strategy = strategySpec;
            selector.matchLabels = selectorLabels compName;
            template = {
              metadata = {
                labels = selectorLabels compName;
              }
              // lib.optionalAttrs config.useConfigMap {
                annotations = {
                  "checksum/config" = self.configmap.out.identityHash;
                };
              };
              spec =
                mkPodSpec self {
                  containers = [ (mkBackendContainer self) ];
                  initContainers = config.backend.initContainers;
                }
                // lib.optionalAttrs (config.backend.topologySpreadConstraints != [ ]) {
                  topologySpreadConstraints = config.backend.topologySpreadConstraints;
                };
            };
          };
        }
        |> scope.mkDeployment;

      # ── Backend Service ─────────────────────────────────────────────
      backendService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${rName}-${compName}-internal";
        labels = componentLabels compName // config.extraServiceLabels;
        spec = {
          type = "ClusterIP";
          selector = selectorLabels compName;
          ports = [
            {
              name = "http";
              port = servicePort;
              targetPort = config.backend.port;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          port = toString servicePort;
        };
        requires = [
          self.backendDeployment
        ]
        ++ lib.optional (self.serviceAccount != null) self.serviceAccount;
      };

      # ── Backend HPA ─────────────────────────────────────────────────
      backendHpa =
        if config.backend.hpa.enabled then
          scope.mkResource {
            apiVersion = "autoscaling/v2";
            kind = "HorizontalPodAutoscaler";
            name = "${rName}-${compName}";
            labels = componentLabels compName;
            spec = {
              scaleTargetRef = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = self.backendDeployment.out.name;
              };
              minReplicas = config.backend.hpa.minReplicas;
              maxReplicas = config.backend.hpa.maxReplicas;
              metrics = [
                {
                  type = "Resource";
                  resource = {
                    name = "cpu";
                    target = {
                      type = "Utilization";
                      averageUtilization = config.backend.hpa.targetCPU;
                    };
                  };
                }
              ];
            }
            // lib.optionalAttrs (config.backend.hpa ? behavior) {
              behavior = config.backend.hpa.behavior;
            };
          }
        else
          null;

      # ── PodDisruptionBudget ──────────────────────────────────────────
      pdb =
        if config.pdb.enabled then
          scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = "${rName}-${compName}";
            labels = componentLabels compName;
            spec = {
              selector.matchLabels = selectorLabels compName;
            }
            // lib.optionalAttrs (config.pdb.minAvailable != null) {
              minAvailable = config.pdb.minAvailable;
            }
            // lib.optionalAttrs (config.pdb.maxUnavailable != null) {
              maxUnavailable = config.pdb.maxUnavailable;
            };
          }
        else
          null;

      # ── Frontend Deployment ─────────────────────────────────────────
      frontendDeployment =
        if config.frontend.enabled then
          {
            name = "${name}-frontend";
            labels = componentLabels "frontend";
            spec = {
              replicas = config.frontend.replicaCount;
              strategy = {
                rollingUpdate = {
                  maxSurge =
                    if config.frontend.strategy.maxSurge != null then
                      config.frontend.strategy.maxSurge
                    else
                      config.maxSurge;
                }
                // lib.optionalAttrs (config.frontend.strategy.maxUnavailable != null) {
                  maxUnavailable = config.frontend.strategy.maxUnavailable;
                };
                type = "RollingUpdate";
              };
              selector.matchLabels = selectorLabels "frontend";
              template = {
                metadata = {
                  labels = selectorLabels "frontend";
                }
                // lib.optionalAttrs config.frontend.useConfigMap {
                  annotations = {
                    "checksum/config" = self.frontendConfigmap.out.identityHash;
                  };
                };
                spec = mkPodSpec self {
                  containers = [ (mkFrontendContainer self) ];
                  volumes = [ ];
                };
              };
            };
          }
          |> scope.mkDeployment
        else
          null;

      # ── Frontend Service ────────────────────────────────────────────
      frontendService =
        if config.frontend.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-frontend-internal";
            labels = componentLabels "frontend";
            spec = {
              type = "ClusterIP";
              selector = selectorLabels "frontend";
              ports = [
                {
                  name = "http";
                  port =
                    if config.frontend.servicePort or null != null then
                      config.frontend.servicePort
                    else
                      config.frontend.port;
                  targetPort = config.frontend.port;
                  protocol = "TCP";
                }
              ];
            };
            outputs = {
              port = toString (
                if config.frontend.servicePort or null != null then
                  config.frontend.servicePort
                else
                  config.frontend.port
              );
            };
            requires = [ self.frontendDeployment ];
          }
        else
          null;

      # ── Caddy Deployment ────────────────────────────────────────────
      caddyDeployment =
        if config.caddy.enabled then
          {
            name = "${name}-caddy";
            labels = componentLabels "caddy";
            spec = {
              replicas = config.caddy.replicaCount;
              strategy.rollingUpdate.maxSurge = "100%";
              selector.matchLabels = selectorLabels "caddy";
              template = {
                metadata.labels = selectorLabels "caddy";
                spec = mkPodSpec self {
                  containers = [
                    {
                      name = "caddy";
                      image = "${config.caddy.image.repository}:${config.caddy.image.tag}";
                      imagePullPolicy = config.caddy.image.pullPolicy;
                      ports = [
                        (kix.port "http" config.caddy.port)
                      ];
                      env = kix.mkEnvVars {
                        BACKEND_HOST = self.backendService.out.name;
                        BACKEND_PORT = toString config.backend.port;
                        FRONTEND_HOST = if config.frontend.enabled then self.frontendService.out.name else null;
                        FRONTEND_PORT = if config.frontend.enabled then toString config.frontend.port else null;
                      };
                      resources = config.caddy.resources;
                    }
                  ];
                  volumes = [ ];
                };
              };
            };
          }
          |> scope.mkDeployment
        else
          null;

      # ── Caddy Service ───────────────────────────────────────────────
      caddyService =
        if config.caddy.enabled then
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
                  port = config.caddy.port;
                  targetPort = "http";
                  protocol = "TCP";
                }
              ];
            };
            outputs = {
              port = toString config.caddy.port;
            };
            requires = [ self.caddyDeployment ];
          }
        else
          null;

      # ── Caddy HPA ──────────────────────────────────────────────────
      caddyHpa =
        if config.caddy.enabled && config.caddy.hpa.enabled then
          scope.mkResource {
            apiVersion = "autoscaling/v2";
            kind = "HorizontalPodAutoscaler";
            name = "${name}-caddy";
            labels = componentLabels "caddy";
            spec = {
              scaleTargetRef = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = self.caddyDeployment.out.name;
              };
              minReplicas = config.caddy.hpa.minReplicas;
              maxReplicas = config.caddy.hpa.maxReplicas;
              metrics = [
                {
                  type = "Resource";
                  resource = {
                    name = "cpu";
                    target = {
                      type = "Utilization";
                      averageUtilization = config.caddy.hpa.targetCPU;
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
        if config.redis.enabled then
          {
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
                      image = "${config.redis.image.repository}:${config.redis.image.tag}";
                      ports = [
                        (kix.port "redis" 6379)
                      ];
                      resources = config.redis.resources;
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
          |> scope.mkDeployment
        else
          null;

      # ── Redis Service ───────────────────────────────────────────────
      redisService =
        if config.redis.enabled then
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

      # ── Ingress (DI-driven) ────────────────────────────────────────
      # Created automatically when ingressNginx is injected and hosts are set.
      # TLS is auto-enabled when clusterIssuer is injected.
      ingress =
        if hasIngress then
          let
            resolveServiceName =
              svcName:
              if svcName == "backend" then
                self.backendService.out.name
              else if svcName == "frontend" && config.frontend.enabled then
                self.frontendService.out.name
              else if svcName == "caddy" && config.caddy.enabled then
                self.caddyService.out.name
              else
                svcName;

            resolveServicePort =
              svcName:
              if svcName == "backend" then
                servicePort
              else if svcName == "frontend" then
                config.frontend.port
              else if svcName == "caddy" then
                config.caddy.port
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
            }) config.ingress.hosts;

            autoTls = config.ingress.autoTls or true;
            tlsSpec =
              if config.ingress.tls != [ ] then
                config.ingress.tls
              else if autoTls then
                let
                  hosts = map (h: h.host) config.ingress.hosts;
                in
                if hosts != [ ] then
                  [
                    {
                      secretName = "${rName}-tls";
                      inherit hosts;
                    }
                  ]
                else
                  [ ]
              else
                [ ];
          in
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "Ingress";
            name = "${rName}-${compName}";
            labels = componentLabels "ingress";
            annotations = config.ingress.annotations;
            spec = {
              ingressClassName = ingressNginx.out.ingressClassName;
              inherit rules;
            }
            // lib.optionalAttrs (tlsSpec != [ ]) {
              tls = tlsSpec;
            };
          }
          |> (if hasTls then clusterIssuer.out.withCert else lib.id)
          |> scope.mkResource
        else
          null;

      # ── Migration Hook (Job) ────────────────────────────────────────
      migrateJob =
        if config.hooks.migrate.enabled then
          scope.mkResource {
            apiVersion = "batch/v1";
            kind = "Job";
            name = "${name}-migrate";
            labels = componentLabels "migrate";
            annotations = {
              ${kix.keys.hook} = "pre-deploy";
              ${kix.keys.hookDeletePolicy} = "before-hook-creation,hook-succeeded";
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
                      image = "${config.backend.image.repository}:${config.backend.image.tag}";
                      imagePullPolicy = config.backend.image.pullPolicy;
                      command = config.hooks.migrate.command;
                      envFrom = mkEnvFrom self self.configmap config.backend.secrets;
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
      root = {
        resource = if config.caddy.enabled then self.caddyService else self.backendService;
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
    // customProcessParts;
}
