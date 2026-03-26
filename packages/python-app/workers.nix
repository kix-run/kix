# workers.nix — build part: queue workers, cron workers, custom processes.
{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;
  h = import ./helpers.nix {
    inherit
      name
      config
      lib
      kix
      scope
      postgres
      valkey
      ;
  };
  inherit (h)
    componentLabels
    selectorLabels
    mkWorkerDeployment
    mkWorkerHpa
    ;

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

in
queueWorkerParts // cronWorkerParts // customProcessParts
