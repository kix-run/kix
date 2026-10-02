# immich-machine-learning: the Immich machine-learning worker, which runs
# face recognition, smart search, OCR and duplicate detection for
# immich-server over HTTP. One Deployment and its Service on port 3003. It
# answers the `machineLearning` dependency of the `immich` package and must
# run the same release (release.nix).
#
# Models download from Hugging Face (and, for OCR, modelscope) on first use
# into /cache. Without a dependency that cache is an emptyDir per pod. An
# optional `modelCache` dependency, a persistent-volume-claim instance,
# keeps it across restarts:
#
#   instances.photos.ml-cache = {
#     package = packages.persistent-volume-claim;
#     aliases = [ "modelCache" ];
#     config.size = "10Gi";
#   };
#
# The package does not know the claim's access mode and treats it as
# ReadWriteOnce, so with `modelCache` the worker runs one pod and rolls out
# with Recreate. To run several pods, leave it unset.
#
# out: the Service's `name`, `fqdn` and `port`, and `version`, the release
# the image tag names (absent for a tag that names none).

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  who = "immich-machine-learning ${scope.namespaceName}/${name}";
  release = import ../immich/release.nix;
in
{
  meta = {
    version = release.version;
    description = "Immich machine-learning worker for face recognition, smart search and duplicate detection, called by immich-server over HTTP";
    owner = "app-team";
    defaultAliases = [ "machineLearning" ];
    # Models download on first use from Hugging Face and, for OCR,
    # modelscope.
    network.intents.model-download.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/immich-app/immich-machine-learning";
      inherit (release) tag;
      digest = release.digests.machineLearning;
      description = ''
        Container image for this instance. Immich publishes hardware
        variants under suffixed tags (`-cuda`, `-openvino`, `-rocm`,
        `-armnn`, `-rknn`); a variant tag runs unpinned unless `digest` is
        set. Request the accelerator in `resources`, for example
        `limits."nvidia.com/gpu" = 1`.
      '';
    };
    # Neither the immich-charts chart nor the compose file sets resources.
    # With the default CLIP and facial-recognition models loaded the worker
    # held about 1 GiB on kind; the limit leaves room for larger models.
    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "1Gi";
      };
      limits = {
        cpu = "4";
        memory = "4Gi";
      };
    };
    env = kix.options.env // {
      description = ''
        Extra environment variables for the worker, such as the
        `MACHINE_LEARNING_*` settings (model TTL, workers, preloading): a
        string, a `fieldRef`, or `kix.untrackedRef` for a Secret managed
        outside Kix. The package refuses `IMMICH_PORT` and
        `MACHINE_LEARNING_CACHE_FOLDER`, which it fixes to match the
        Service, probes and /cache mount.
      '';
    };
  };

  build =
    {
      self,
      config,
      modelCache ? null,
      ...
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
      cached = modelCache != null;
      version = release.of config.image.tag;
    in
    {
      cacheMount =
        if cached then
          kix.mount.pvc modelCache { mountPath = "/cache"; }
        else
          kix.mount.emptyDir {
            name = "cache";
            mountPath = "/cache";
          };

      deployment =
        {
          inherit name;
          spec = {
            replicas =
              if cached then
                1
              else
                kix.availability.pick availability {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 3;
                };
            ${if cached then "strategy" else null} = {
              type = "Recreate";
            };
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              # Kubernetes default: Immich documents no shutdown drain.
              terminationGracePeriodSeconds = 30;
              automountServiceAccountToken = false;
              # The image defines no user. Immich supports any non-root uid
              # that can write /cache (docs FAQ, "run as non-root").
              # OnRootMismatch relabels the cache only while its root lacks
              # the group.
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 1000;
                runAsGroup = 1000;
                fsGroup = 1000;
                fsGroupChangePolicy = "OnRootMismatch";
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "immich-machine-learning";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  # The image points TRANSFORMERS_CACHE and
                  # MACHINE_LEARNING_CACHE_FOLDER at /cache. The root
                  # filesystem is read-only, so the Hugging Face transfer
                  # cache and matplotlib's config, which default to $HOME,
                  # go there too.
                  env = kix.mkEnvVars (
                    kix.mergeEnv {
                      inherit who;
                      defaults = {
                        HF_XET_CACHE = "/cache/huggingface-xet";
                        MPLCONFIGDIR = "/cache/matplotlib-config";
                      };
                      owned = [
                        {
                          names = [
                            "IMMICH_PORT"
                            "MACHINE_LEARNING_CACHE_FOLDER"
                          ];
                          from = "the package, which fixes the worker's port and cache path to match its Service, probes and /cache mount";
                          fix = "Remove the setting from env.";
                        }
                      ];
                    } config.env
                  );
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
                    capabilities.drop = [ "ALL" ];
                  };
                }
              ];
            };
          };
        }
        // lib.optionalAttrs cached { availability.max = "none"; }
        |> kix.withMounts [
          self.cacheMount
          (kix.mount.emptyDir {
            name = "tmp";
            mountPath = "/tmp";
          })
        ]
        |> scope.mkDeployment;

      service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

      root = {
        resource = self.service;
        out = lib.optionalAttrs (version != null) { inherit version; };
      };
    };
}
