# backend.nix — build part: backend Deployment, Service, HPA, PDB.
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
    rName
    compName
    servicePort
    componentLabels
    selectorLabels
    mkPodSpec
    mkBackendContainer
    strategySpec
    ;
in
{
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
}
