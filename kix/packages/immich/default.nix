# Immich server: kix package.
#
# Deploys the Immich API and web UI. Requires valkey (Redis-compatible)
# for job queues. Optionally connects to an immich-machine-learning
# instance for smart features (facial recognition, search, etc.).
#
# Dependencies:
#   valkey                required, job queue backend; reached through
#                          Sentinel when the valkey instance runs it
#   database              required, logical database (provided by stackgres-database
#                          or any package exposing the same out.{host,port,database,
#                          credentials,connectionEnv} interface). The underlying
#                          postgres cluster must have the "vector" extension installed.
#   storage               required, persistent volume for photo library
#   machineLearning       optional, ML inference service
#   prometheus            optional, auto-creates ServiceMonitor when present (+ metrics enabled)
#
# Resources: Deployment, Service, optional ConfigMap, optional ServiceMonitor.
# Ingress handled via kix.expose.
#
# root = Service (port 2283).

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  release = import ./release.nix;

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
    description = "Immich: self-hosted photo management";
    owner = "app-team";
    # The server mounts the photo library from a single ReadWriteOnce
    # claim and runs the job workers in-process, so it is single-writer.
    availability.max = "none";
    compatibleWith.database = {
      reason = "immich requires the VectorChord (vchord) extension plus uuid-ossp, cube, earthdistance, unaccent, pg_trgm on its postgres backend";
    };
  };

  # Per-dep diagnostics + config injections, co-located with the dep.
  deps = {
    # Declare the database extensions immich requires. The stackgres-database
    # package picks these up via dep config injection and (a) runs
    # CREATE EXTENSION on the new database, (b) forwards them to the
    # underlying stackgres-cluster so the operator installs them on the
    # postgres image. End result: immich auto-instantiation pulls a fully
    # configured database + cluster with no cluster-side wiring.
    database.config = {
      # Immich's InitialMigration creates these extensions on first boot:
      #   - vchord       : VectorChord, image similarity embeddings
      #                    (upstream Immich's current default; picked by
      #                    getVectorExtension() in preference to `vectors`
      #                    and legacy `vector` / pgvector)
      #   - uuid-ossp    : UUID generation for primary keys
      #   - cube         : required by earthdistance (GPS coordinates)
      #   - earthdistance: geo distance queries for the map view
      #   - unaccent     : accent-insensitive search on metadata
      #   - pg_trgm      : trigram similarity search on text fields
      # Source of truth: Immich's InitialMigration
      # (server/src/schema/migrations/1744910873969-InitialMigration.ts)
      # runs CREATE EXTENSION for exactly this set.
      # Missing any of these fails InitialMigration with
      #   0A000 "extension <X> is not available".
      # StackGres ships a minimal postgres image; extensions must be
      # declared here so stackgres-database can forward them to the
      # cluster and the operator installs them on the image.
      extensions = [
        {
          name = "vchord";
          version = "0.5.3";
        }
        "uuid-ossp"
        "cube"
        "earthdistance"
        "unaccent"
        "pg_trgm"
      ];
    };

    # Validate that the database instance was configured with all of
    # immich's required extensions. The stackgres-database package
    # translates `extensions = [...]` into CREATE EXTENSION statements
    # run against the new database; each extension still has to be
    # installed on the underlying SGCluster.
    database.assertions =
      dep:
      let
        extensions = dep.out.extensions or null;
        # Extensions can be strings or `{ name, version? }` attrsets; reduce
        # to just names for the presence check.
        extensionNames =
          if extensions == null then null else map (e: if builtins.isString e then e else e.name) extensions;
        required = [
          "vchord"
          "uuid-ossp"
          "cube"
          "earthdistance"
          "unaccent"
          "pg_trgm"
        ];
        missing = lib.filter (e: !(builtins.elem e extensionNames)) required;
      in
      lib.optional (extensions != null && missing != [ ]) {
        assertion = false;
        message = "immich requires the following postgres extensions on its database: ${lib.concatStringsSep ", " required}. Missing: ${lib.concatStringsSep ", " missing}. Add them to the stackgres-database instance's `extensions` and ensure the underlying stackgres-cluster declares them under `extensions`.";
      };

    storage.warnings =
      dep:
      let
        storageSizeGi = kix.parseGi (dep.out.size or "0");
      in
      lib.optional (storageSizeGi != null && storageSizeGi < 50)
        "library storage is ${dep.out.size or "unknown"}; recommended minimum is 50Gi for photo libraries";
  };

  # Printed on the build that passes too, as the reminder to undo the
  # override afterwards.
  warnings =
    { config, ... }:
    lib.optional config.initChownData chownOverrideHint;

  options = {
    image = kix.options.image {
      repository = "ghcr.io/immich-app/immich-server";
      tag = release.version;
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Pinned to one at every level: see meta.availability.max.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 1;
        zone = 1;
      };
      description = ''
        Number of immich-server replicas. Pinned to one at every
        availability level (v2_discussions/145) because the server is
        single-writer over the library volume.
      '';
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra environment variables for the server container. When the
        valkey instance runs Sentinel, the container builds `REDIS_URL` at
        start from `REDIS_SENTINEL_OPTIONS` and `REDIS_PASSWORD`, which
        replaces a `REDIS_URL` set here, and a `REDIS_PASSWORD_FILE` set
        here does not reach it.
      '';
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
    # Neither the immich-charts chart nor the compose file sets resources.
    # Immich's requirements page asks for 6 GB of RAM and 2 cores for the
    # whole stack; the server's share leaves room for thumbnail and video
    # jobs, which run in-process.
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
    ingress = kix.options.ingress;
    initChownData = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run `chown -R 1000:1000 /usr/src/app/upload` as root in an init
        container before immich-server starts. The server runs as uid
        1000, and fsGroup does not change ownership on hostPath or
        local-path volumes, so a library written by an earlier root-run
        release stays unwritable. The chown walks the whole library, so a
        large one takes a while. Enable this for the first deploy after
        such an upgrade. The init container fails the `security.nonRoot`
        scorecard rule, so that deploy also needs
        `scorecard.ruleOverrides.byNamespace.<namespace>."security.nonRoot".severity = "warning"`.
        Remove both once the pod has started.
      '';
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        valkey,
        database,
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
        # A worker from another release answers the server's newer jobs with
        # 500s. `out.version` is the worker's release (see release.nix `of`),
        # so hardware variants and digest pins compare by release. It is
        # absent for a tag that names no release and on a machine-learning
        # dep that is not the immich-machine-learning package, such as a
        # Service import; either skips the check.
        mlVersion = machineLearning.out.version or null;
        serverVersion = release.of config.image.tag;
        mlUrl =
          if !hasMl then
            null
          else if mlVersion != null && serverVersion != null && mlVersion != serverVersion then
            throw "immich '${name}': immich-server is ${serverVersion} (image.tag ${config.image.tag}) but its machine-learning instance runs ${mlVersion}. Immich releases both images under one tag; set image.tag to the same release on both instances."
          else
            "http://${machineLearning.out.fqdn}:${machineLearning.out.port}";

        hasMetrics = config.metrics.enabled && prometheus != null;

        # With Sentinel on, the valkey Service also routes to read-only
        # replicas, so the server finds the primary through Sentinel.
        # Immich takes ioredis options as REDIS_URL=ioredis://<base64 JSON>
        # and then ignores the other REDIS_* variables, so the password has
        # to go into that JSON. The container builds REDIS_URL from
        # REDIS_SENTINEL_OPTIONS and REDIS_PASSWORD at start, which keeps
        # the password in its Secret. See
        # https://docs.immich.app/install/environment-variables#redis
        useSentinel = valkey.out ? sentinelPort;
        sentinelStart = ''
          set -e
          REDIS_URL="ioredis://$(node -e 'const o = JSON.parse(process.env.REDIS_SENTINEL_OPTIONS); if (process.env.REDIS_PASSWORD) o.password = process.env.REDIS_PASSWORD; process.stdout.write(Buffer.from(JSON.stringify(o)).toString("base64"))')"
          export REDIS_URL
          exec start.sh
        '';
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
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
        };

        # --- Server Deployment ---
        deployment =
          {
            name = "${name}-server";
            spec = {
              replicas = config.replicaCount;
              selector.matchLabels = scope.selectorLabels;
              strategy.type = "RollingUpdate";
              # Kubernetes default: Immich documents no shutdown drain.
              template.spec.terminationGracePeriodSeconds = 30;
              # uid 1000 is the image's `node` user. Immich supports any
              # non-root uid that can write the library (docs FAQ, "run as
              # non-root"); fsGroup grants that on provisioners that honour it.
              # OnRootMismatch relabels the library only while its root lacks
              # the group, not on every start.
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
                      self.libraryMount.mountPath
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
                    volumeMounts = [ { inherit (self.libraryMount) name mountPath; } ];
                  }
              );
              template.spec.containers = [
                {
                  name = "immich-server";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  # The image's entrypoint is `tini -- /bin/bash -c` with
                  # CMD `start.sh`, so args replaces only the command string.
                  ${if useSentinel then "args" else null} = [ sentinelStart ];
                  # kix.mkEnv combines { KEY = "val"; } entries with raw K8s env
                  # entries (e.g. valueFrom.secretKeyRef). Null values in the
                  # attrset are filtered, so disabled features just set null.
                  env =
                    kix.mkEnv
                      (
                        {
                          DB_HOSTNAME = database.out.host;
                          DB_PORT = database.out.port;
                          DB_DATABASENAME = database.out.database;
                          REDIS_HOSTNAME = if useSentinel then null else valkey.out.fqdn;
                          REDIS_SENTINEL_OPTIONS =
                            if useSentinel then
                              builtins.toJSON {
                                sentinels = [
                                  {
                                    host = valkey.out.fqdn;
                                    port = valkey.out.sentinelPort;
                                  }
                                ];
                                name = valkey.out.primarySet;
                              }
                            else
                              null;
                          IMMICH_MACHINE_LEARNING_URL = mlUrl;
                          IMMICH_CONFIG_FILE =
                            if self.configMount != null then "${self.configMount.mountPath}/immich-config.yaml" else null;
                          IMMICH_TELEMETRY_INCLUDE = if config.metrics.enabled then "all" else null;
                        }
                        // config.env
                      )
                      (
                        # Pull immich's per-app db credentials from the database
                        # instance's local Secret (in *this* namespace: no
                        # cross-namespace secret reads, no superuser exposure).
                        (database.out.credentials.out.mkEnv {
                          DB_USERNAME = "username";
                          DB_PASSWORD = "password";
                        })
                        # Pull the valkey password from its credentials secret when
                        # auth is enabled. Without this, immich fails with NOAUTH.
                        ++ lib.optionals (valkey.out ? authSecret) [
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
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                  };
                }
              ];
            };
          }
          # kix.withMounts injects volumes + volumeMounts into the pod spec.
          # This will work if there is only one container, if multiple containers are in the deployment, the containerName must be passed as well otheriwse error.
          # Nulls are filtered; disabled mounts are silently skipped.
          # TODO: should trigger an error if the same volume name is used multiple times (which can happen with the auto-naming)
          |> kix.withMounts [
            self.libraryMount
            self.configMount
            self.tmpMount
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
        # Builder comes from prometheus.out.mkServiceMonitor; no local CRDRef needed.
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
      # The mobile app's /api/sync/stream is a long-lived streaming endpoint;
      # a fresh session's initial full sync exceeds Envoy Gateway's default 15s
      # request timeout (observed UT cuts), which stalls the album backfill and
      # blocks photo backup. Disable the request timeout so the stream can run
      # to completion (the app's own 60s socket timeout remains the bound).
      timeouts = {
        request = "0s";
        backendRequest = "0s";
      };
    })
  ];
}
