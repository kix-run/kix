# Immich machine-learning worker — kix package.
#
# ML inference service for Immich: facial recognition, smart search,
# duplicate detection. Runs independently — immich-server connects
# to it via HTTP.
#
# Resources: Deployment, Service, optional PersistentVolumeClaim (model cache).
#
# main = Service (port 3003).

{
  scope,
  lib,
}:

let
  name = scope.instanceName;
in
{
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
      default = 1;
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

  build = { self, config, clusterConfig }:
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
          } // lib.optionalAttrs (config.persistence.storageClass != null) {
            storageClassName = config.persistence.storageClass;
          };
        }
      else
        null;

    # --- Deployment ---
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = name;
      spec = {
        replicas = config.replicaCount;
        selector.matchLabels = scope.selectorLabels;
        strategy.type = "RollingUpdate";
        template = {
          metadata.labels = scope.selectorLabels;
          spec = {
            containers = [
              {
                name = "immich-machine-learning";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                env = [
                  { name = "TRANSFORMERS_CACHE"; value = "/cache"; }
                  { name = "HF_XET_CACHE"; value = "/cache/huggingface-xet"; }
                  { name = "MPLCONFIGDIR"; value = "/cache/matplotlib-config"; }
                ];
                ports = [
                  { name = "http"; containerPort = 3003; protocol = "TCP"; }
                ];
                livenessProbe = {
                  httpGet = { path = "/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = { path = "/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 3;
                };
                startupProbe = {
                  httpGet = { path = "/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 60;
                };
                volumeMounts = [
                  { name = "cache"; mountPath = "/cache"; }
                ];
              }
            ];
            volumes = [
              (if config.persistence.enabled then {
                name = "cache";
                persistentVolumeClaim.claimName = self.cachePvc.out.name;
              } else {
                name = "cache";
                emptyDir = { };
              })
            ];
          };
        };
      };
    };

    # --- Service ---
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = name;
      spec = {
        type = "ClusterIP";
        selector = self.deployment.out.selector;
        ports = [
          { name = "http"; port = 3003; targetPort = "http"; protocol = "TCP"; }
        ];
      };
      outputs = {
        port = "3003";
      };
      requires = lib.optional (self.cachePvc != null) self.cachePvc;
    };

    # --- Entry point ---
    main = self.service;
  };
}
