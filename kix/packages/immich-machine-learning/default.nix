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
  release = import ../immich/release.nix;

  # init-chown-data runs as root. When security.nonRoot would fail the
  # build, fail it here instead with the override that lets the migration
  # deploy through.
  chownOverrideHint = "initChownData adds the root init container init-chown-data, which fails the security.nonRoot scorecard rule. For the migration deploy, set scorecard.ruleOverrides.byNamespace.${scope.namespaceName}.\"security.nonRoot\".severity = \"warning\" in the cluster definition. Once the pod has started, remove that override and set initChownData = false.";
  nonRootFailsBuild =
    clusterConfig:
    kix.scorecard.effectiveSeverity {
      inherit clusterConfig;
      rule = "security.nonRoot";
      namespaceName = scope.namespaceName;
      owner = "app-team";
    } == "error";
in
{
  meta = {
    version = release.version;
    description = "Immich machine-learning worker for face recognition, smart search and duplicate detection, called by immich-server over HTTP";
    owner = "app-team";
    # Keep the `machineLearning` build argument while using a lowercase
    # Kubernetes instance name.
    defaultAliases = [ "machineLearning" ];
    # persistence.enabled hand-rolls the model-cache claim; the preferred
    # path is a `storage` dep + sibling persistent-volume-claim instance.
    # Grant kept until refactored (audited by unsafeGrants).
    unsafe = [
      "raw-pvc"
    ];
  };

  # Printed on the build that passes too, as the reminder to undo the
  # override afterwards.
  warnings =
    { config, ... }:
    lib.optional config.initChownData chownOverrideHint;

  options = {
    image = kix.options.image {
      repository = "ghcr.io/immich-app/immich-machine-learning";
      tag = release.version;
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
    initChownData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run `chown -R 1000:1000 /cache` as root in an init container
        before the model server starts. It runs as uid 1000, and fsGroup
        does not change ownership on hostPath or local-path volumes, so a
        cache volume written by an earlier root-run release stays
        unwritable. This matters only with persistence.enabled, and
        deleting the claim so the models download again works too. Enable
        this for the first deploy after such an upgrade. The init container
        fails the `security.nonRoot` scorecard rule, so that deploy also
        needs
        `scorecard.ruleOverrides.byNamespace.<namespace>."security.nonRoot".severity = "warning"`.
        Remove both once the pod has started.
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
    # Neither the immich-charts chart nor the compose file sets resources.
    # With the default CLIP and facial-recognition models loaded the worker
    # held about 1 GiB on kind; the limit leaves room for larger models.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "250m";
          memory = "1Gi";
        };
        limits = {
          cpu = "4";
          memory = "4Gi";
        };
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
            # Kubernetes default: Immich documents no shutdown drain.
            template.spec.terminationGracePeriodSeconds = 30;
            # The image defines no user. Immich supports any non-root uid that
            # can write /cache (docs FAQ, "run as non-root"). OnRootMismatch
            # relabels the cache only while its root lacks the group.
            template.spec.securityContext = {
              runAsNonRoot = true;
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            template.spec.${if config.initChownData then "initContainers" else null} = lib.singleton (
              if nonRootFailsBuild clusterConfig then
                throw "${name}: ${chownOverrideHint}"
              else
                {
                  name = "init-chown-data";
                  image = "docker.io/library/busybox:1.38.0";
                  command = [
                    "chown"
                    "-R"
                    "1000:1000"
                    self.cacheMount.mountPath
                  ];
                  securityContext = {
                    runAsNonRoot = false;
                    runAsUser = 0;
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities = {
                      add = [ "CHOWN" ];
                      drop = [ "ALL" ];
                    };
                  };
                  volumeMounts = [ { inherit (self.cacheMount) name mountPath; } ];
                }
            );
            template.spec.containers = [
              {
                name = "immich-machine-learning";
                image = kix.image.ref config.image;
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
                resources = config.resources;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                };
              }
            ];
          };
        }
        |> kix.withMounts [
          self.cacheMount
          (kix.mount.emptyDir {
            name = "tmp";
            mountPath = "/tmp";
          })
        ]
        |> scope.mkDeployment;

      # --- Service ---
      service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

      # --- Entry point ---
      # `version` is the release the image tag names, which immich-server
      # compares with its own. A tag that names no release leaves it out.
      root = {
        resource = self.service;
        out = lib.optionalAttrs (release.of config.image.tag != null) {
          version = release.of config.image.tag;
        };
      };
    };
}
