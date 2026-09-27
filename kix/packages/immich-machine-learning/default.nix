# Immich machine-learning worker — kix package.
#
# ML inference service for Immich: facial recognition, smart search,
# duplicate detection. Runs independently — immich-server connects
# to it via HTTP.
#
# Resources: Deployment, Service, optional PersistentVolumeClaim (model cache).
#
# root = Service (port 3003).

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "v2.0.0";
    description = "Immich machine-learning worker for face recognition, smart search and duplicate detection, called by immich-server over HTTP";
    owner = "app-team";
    # Keep the `machineLearning` build argument while using a lowercase
    # Kubernetes instance name.
    defaultAliases = [ "machineLearning" ];
    # persistence.enabled hand-rolls the model-cache claim; the preferred
    # path is a `storage` dep + sibling persistent-volume-claim instance.
    # Grant kept until refactored (audited by unsafeGrants).
    # The upstream image runs as root; the model cache is written by it.
    unsafe = [
      "raw-pvc"
      "run-as-root"
    ];
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "ghcr.io/immich-app/immich-machine-learning";
        tag = "v2.0.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Stateless HTTP inference, so replicas scale out. The optional model
      # cache is ReadWriteOnce: enabling persistence pins pods to one node.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      description = ''
        Number of machine-learning replicas. Defaults from the cluster's
        availability level (v2_discussions/145).
      '';
    };
    persistence = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        size = "10Gi";
        storageClass = null;
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      healthCheck = {
        httpGet = {
          path = "/ping";
          port = "http";
        };
        periodSeconds = 10;
        timeoutSeconds = 1;
        failureThreshold = 3;
      };
    in
    {

      # --- Model cache PVC (optional) ---
      cachePvc =
        if config.persistence.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            name = "${name}-cache";
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = config.persistence.size;
            }
            // lib.optionalAttrs (config.persistence.storageClass != null) {
              storageClassName = config.persistence.storageClass;
            };
          }
        else
          null;

      # --- Mounts ---
      cacheMount =
        if config.persistence.enabled then
          kix.mount.pvc self.cachePvc { mountPath = "/cache"; }
        else
          kix.mount.emptyDir {
            mountPath = "/cache";
            name = "cache";
          };

      # --- Deployment ---
      deployment =
        {
          name = name;
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = scope.selectorLabels;
            strategy.type = "RollingUpdate";
            template.spec.containers = [
              {
                name = "immich-machine-learning";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                env = kix.mkEnvVars {
                  TRANSFORMERS_CACHE = "/cache";
                  HF_XET_CACHE = "/cache/huggingface-xet";
                  MPLCONFIGDIR = "/cache/matplotlib-config";
                };
                ports = [
                  (kix.port "http" 3003)
                ];
                livenessProbe = healthCheck;
                readinessProbe = healthCheck;
                startupProbe = healthCheck // {
                  failureThreshold = 60;
                };
              }
            ];
          };
        }
        |> kix.withMounts [
          self.cacheMount
        ]
        |> scope.mkDeployment;

      # --- Service ---
      service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

      # --- Entry point ---
      root = self.service;
    };
}
