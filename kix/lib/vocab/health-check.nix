# Build post-deploy health check Jobs and script ConfigMaps (`kix.healthCheck`).
{
  lib,
  image,
  mkEnvVars,
  mount,
  withMountsOn,
}:

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  imageRef = image.ref;

  # Reserve 90s after the retry window so one final check round can finish
  # before `activeDeadlineSeconds` expires.
  roundBudget = 90;

  # Update digests with `crane digest <repository>:<tag>` (multi-arch index
  # digest).
  runtimes = {
    python = {
      image = {
        repository = "docker.io/library/python";
        tag = "3.13-slim";
        digest = "sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285";
      };
      file = "health-check.py";
      interpreter = [ "python3" ];
      # Skip bytecode writes because `/` and `/probe` are read-only.
      env.PYTHONDONTWRITEBYTECODE = "1";
    };
    shell = {
      image = {
        repository = "docker.io/curlimages/curl";
        tag = "8.14.1";
        digest = "sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b";
      };
      file = "health-check.sh";
      interpreter = [
        "/bin/sh"
        "-eu"
      ];
      env = { };
    };
  };
in
{
  inherit runtimes roundBudget;
  __functor =
    _:
    # Callbacks receive `{ self, config, deps }`.
    {
      script,
      # Return an attrset of environment variables for the probe container.
      # Values from `out.*` carry dependency and network-policy context.
      env ? (_: { }),
      # Return false to omit the probe resources.
      when ? ({ config, ... }: config.healthCheck.enabled or true),
      # Return the retry window in seconds (`RETRY_FOR`).
      retryFor ? ({ config, ... }: config.healthCheck.retryFor or 90),
      # Return extra resources the probe Job must wait for in addition to
      # `self.root`.
      requires ? (_: [ ]),
      partName ? "healthCheck",
      runtime ? runtimes.python,
      # Override `activeDeadlineSeconds`. Must be at least
      # `retryFor + roundBudget`.
      activeDeadlineSeconds ? null,
    }:
    {
      self,
      config,
      scope,
      deps,
      ...
    }:
    let
      name = scope.instanceName;
      scriptPart = "${partName}Script";
      ctx = {
        inherit self config deps;
      };
      retry = retryFor ctx;
      deadline = if activeDeadlineSeconds == null then retry + roundBudget else activeDeadlineSeconds;
      userEnv = env ctx;
      rootRes =
        let
          r = self.root;
        in
        r.resource or r;
      # The probe reruns when the own content of the root or of a required
      # resource changes, through a `checksum/*` annotation on its pod
      # template. That annotation already makes the Job depend on the
      # resource, so only the required values without a content hash stay
      # in `requires`.
      required = requires ctx;
      hasContentHash = r: (r.out or { }) ? contentHash;
      checkedRequired = builtins.filter (
        r: hasContentHash r && r.outPath or null != rootRes.outPath
      ) required;
      # A resource without a content hash is required unless `userEnv`
      # already references it, which would trigger a redundant-requires
      # warning. A secret-ref the probe reads through `env` is one.
      envContext = builtins.getContext (builtins.toJSON userEnv);
      waitsFor =
        r:
        !(hasContentHash r)
        && !(builtins.hasAttr (builtins.unsafeDiscardStringContext r.outPath) envContext);
      requireRoot = waitsFor rootRes;
      checksums = {
        "checksum/script" = self.${scriptPart}.out.contentHash;
      }
      // lib.optionalAttrs (hasContentHash rootRes) {
        "checksum/root" = rootRes.out.contentHash;
      }
      // builtins.listToAttrs (
        lib.imap0 (
          i: r: lib.nameValuePair "checksum/requires-${toString i}" r.out.contentHash
        ) checkedRequired
      );
    in
    if !(when ctx) then
      { }
    else if deadline < retry + roundBudget then
      scope.fail {
        message = "kix.healthCheck (${name}): activeDeadlineSeconds ${toString deadline} leaves no room for a round of checks after the ${toString retry}s retry window.";
        fix = "Set activeDeadlineSeconds to at least ${toString (retry + roundBudget)}.";
      }
    else
      {
        ${scriptPart} = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-health-script";
          data.${runtime.file} = script;
        };

        ${partName} =
          {
            name = "${name}-health";
            requires = builtins.filter waitsFor required ++ lib.optional requireRoot rootRes;
            annotations.${kixKeys.rerun} = kixAnnotations.values.rerunOnChange;
            spec = {
              backoffLimit = 0;
              activeDeadlineSeconds = deadline;
              template = {
                metadata.labels = {
                  "app.kubernetes.io/name" = "${name}-health";
                  "app.kubernetes.io/component" = "health-check";
                };
                metadata.annotations = checksums;
                spec = {
                  restartPolicy = "Never";
                  automountServiceAccountToken = false;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 65534;
                    runAsGroup = 65534;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "probe";
                      image = imageRef runtime.image;
                      command = runtime.interpreter ++ [ "/probe/${runtime.file}" ];
                      env = mkEnvVars (
                        (runtime.env or { })
                        // {
                          RETRY_FOR = toString retry;
                        }
                        // userEnv
                      );
                      terminationMessagePolicy = "FallbackToLogsOnError";
                      securityContext = {
                        runAsNonRoot = true;
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                      resources = {
                        requests = {
                          cpu = "50m";
                          memory = "64Mi";
                        };
                        limits.memory = "128Mi";
                      };
                    }
                  ];
                };
              };
            };
          }
          |> withMountsOn "probe" [
            (mount.configMap self.${scriptPart} {
              mountPath = "/probe";
              readOnly = true;
            })
          ]
          |> scope.mkJob;
      };
}
