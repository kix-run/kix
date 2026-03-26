# helpers.nix — shared naming, labels, builders for python-app.
# This is a plain function (NOT a build part). Imported by build parts.
{
  name,
  config,
  lib,
  kix,
  scope,
  postgres,
  valkey,
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

  # ── DI-driven env ──────────────────────────────────────────
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
    lib.optional config.useConfigMap { configMapRef.name = configMapName.out.name; }
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
    // lib.optionalAttrs (config.priorityClassName != null) {
      priorityClassName = config.priorityClassName;
    }
    // lib.optionalAttrs config.serviceAccount.enabled {
      serviceAccountName =
        if config.serviceAccount.name != null then config.serviceAccount.name else rName;
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
        ++ map (s: { secretRef.name = s; }) config.frontend.secrets;
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

  # ── Strategy spec ────────────────────────────────────────────────
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
  inherit
    rName
    compName
    containerName
    servicePort
    probePort
    appLabel
    commonLabels
    componentLabels
    selectorLabels
    depEnv
    secretFileNames
    secretVolumes
    secretVolumeMounts
    mkEnvFrom
    mkPodSpec
    mkLivenessProbe
    mkReadinessProbe
    mkBackendContainer
    mkFrontendContainer
    mkWorkerContainer
    mkWorkerDeployment
    mkWorkerHpa
    strategySpec
    ;
}
