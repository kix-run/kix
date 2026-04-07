# Immich server — kix package.
#
# Deploys the Immich API and web UI. Requires valkey (Redis-compatible)
# for job queues. Optionally connects to an immich-machine-learning
# instance for smart features (facial recognition, search, etc.).
#
# Dependencies:
#   valkey              — required, job queue backend
#   postgres            — required, database (needs pgvecto.rs / "vectors" extension)
#   storage             — required, persistent volume for photo library
#   machineLearning     — optional, ML inference service
#   prometheus          — optional, auto-creates ServiceMonitor when present (+ metrics enabled)
#
# Resources: Deployment, Service, optional ConfigMap, optional ServiceMonitor.
# Ingress handled via kix.expose.
#
# root = Service (port 2283).

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
    version = "v2.0.0";
    description = "Immich — self-hosted photo management";
    owner = "app-team";
    provides = [
      "photo-management"
      "media-server"
    ];
    compatibleWith.postgres = {
      minVersion = "15";
      reason = "immich requires pgvecto.rs which needs PG15+";
    };
  };

  # Per-dep diagnostics — co-located with the dep they validate.
  deps = {
    # Config injection: automatically add required extensions to postgres.
    # Uses listOf merge — concatenates with any cluster-defined extensions.
    postgres.config = {
      extensions = [
        {
          name = "vector";
          #publisher = "tensorchord"; # TODO: verify
          #version = "0.8.1";
          #repository = "https://extensions.stackgres.io/postgres/repository";
        }
      ];
    };

    postgres.assertions =
      dep:
      let
        extNames = dep.out.extensionNames or null;
      in
      lib.optional (extNames != null && !(builtins.elem "vector" extNames)) {
        assertion = false;
        message = "immich requires the pgvecto.rs extension (\"vectors\") on its postgres instance, but it is not configured. Add { name = \"vectors\"; publisher = \"tensorchord\"; version = \"...\"; } to postgres.extensions.";
      };

    storage.warnings =
      dep:
      let
        storageSizeGi = kix.parseGi (dep.out.size or "0");
      in
      lib.optional (storageSizeGi != null && storageSizeGi < 50)
        "library storage is ${dep.out.size or "unknown"} — recommended minimum is 50Gi for photo libraries";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "ghcr.io/immich-app/immich-server";
        tag = "v2.0.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the server container";
    };
    configuration = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = "Immich config (immich-config.yaml content as attrset). Null to disable.";
    };
    metrics = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
    };
    ingress = kix.options.ingress;
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        valkey,
        postgres,
        storage,
        scope,
        kix,
        machineLearning ? null,
        prometheus ? null,
        ...
      }:
      let
        hasConfig = config.configuration != null;

        healthCheck = {
          httpGet = {
            path = "/api/server/ping";
            port = "http";
          };
          periodSeconds = 10;
          timeoutSeconds = 1;
          failureThreshold = 3;
        };
        hasMl = machineLearning != null;
        mlUrl = if hasMl then "http://${machineLearning.out.fqdn}:${machineLearning.out.port}" else null;

        hasMetrics = config.metrics.enabled && prometheus != null;
      in
      {

        # --- Optional: Immich configuration ConfigMap ---
        configMap =
          if hasConfig then
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-config";
              data = {
                "immich-config.yaml" = builtins.toJSON config.configuration;
              };
            }
          else
            null;

        # --- Mounts ---
        # kix.mount.* creates a { volume, volumeMount } pair from a resource.
        # Returns null when the resource is null (configMap disabled → configMount = null).
        # Volume name auto-derives from the resource's out.name.
        libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
        configMount = kix.mount.configMap self.configMap { mountPath = "/config"; };

        # --- Server Deployment ---
        deployment =
          {
            name = "${name}-server";
            spec = {
              replicas = config.replicaCount;
              selector.matchLabels = scope.selectorLabels;
              strategy.type = "RollingUpdate";
              template.spec.containers = [
                {
                  name = "immich-server";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  # kix.mkEnv combines { KEY = "val"; } entries with raw K8s env
                  # entries (e.g. valueFrom.secretKeyRef). Null values in the
                  # attrset are filtered, so disabled features just set null.
                  env =
                    kix.mkEnv
                      (
                        {
                          DB_HOSTNAME = postgres.out.fqdn;
                          DB_PORT = postgres.out.port;
                          REDIS_HOSTNAME = valkey.out.fqdn;
                          IMMICH_MACHINE_LEARNING_URL = mlUrl;
                          IMMICH_CONFIG_FILE =
                            if self.configMount != null then "${self.configMount.mountPath}/immich-config.yaml" else null;
                          IMMICH_TELEMETRY_INCLUDE = if config.metrics.enabled then "all" else null;
                        }
                        // config.env
                      )
                      (
                        # Pull the valkey password from its credentials secret when
                        # auth is enabled. Without this, immich fails with NOAUTH.
                        lib.optionals (valkey.out ? authSecret) [
                          (
                            (valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey)
                            // {
                              name = "REDIS_PASSWORD";
                            }
                          )
                        ]
                      );
                  ports = [
                    (kix.port "http" 2283)
                  ]
                  ++ lib.optionals config.metrics.enabled [
                    (kix.port "metrics-api" 8081)
                    (kix.port "metrics-ms" 8082)
                  ];
                  livenessProbe = healthCheck;
                  readinessProbe = healthCheck;
                  startupProbe = healthCheck // {
                    failureThreshold = 30;
                  };
                }
              ];
            };
          }
          # kix.withMounts injects volumes + volumeMounts into the pod spec.
          # This will work if there is only one container, if multiple containers are in the deployment, the containerName must be passed as well otheriwse error.
          # Nulls are filtered — disabled mounts are silently skipped.
          # TODO: should trigger an error if the same volume name is used multiple times (which can happen with the auto-naming)
          |> kix.withMounts [
            self.libraryMount
            self.configMount
          ]
          # scope.mkDeployment sets apiVersion/kind, auto-copies selector to
          # template labels (preventing mismatch), then compiles to storepath via mkResource.
          |> scope.mkDeployment;

        # --- Server Service ---
        # kix.service.fromWorkload auto-derives selector and ports from the
        # deployment's container spec. Returns a pre-seal attrset → mkResource seals it.
        service =
          self.deployment |> kix.service.fromWorkload { name = "${name}-server"; } |> scope.mkResource;

        # --- ServiceMonitor (DI-driven) ---
        # Created when prometheus is injected AND metrics are enabled.
        # Builder comes from prometheus.out.mkServiceMonitor — no local CRDRef needed.
        serviceMonitor =
          if hasMetrics then
            prometheus.out.mkServiceMonitor scope {
              name = name;
              spec = {
                namespaceSelector.matchNames = [ scope.namespaceName ];
                selector.matchLabels = self.service.out.selector;
                endpoints = [
                  {
                    port = "metrics-api";
                    scheme = "http";
                  }
                  {
                    port = "metrics-ms";
                    scheme = "http";
                  }
                ];
              };
            }
          else
            null;

        # --- Entry point ---
        root = self.service;
      }
    )
    (kix.expose {
      service = "service";
      defaultAnnotations = {
        "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
      };
    })
  ];
}
