# tempo: Grafana Tempo as one single-binary pod on one volume.
#
# One StatefulSet pod runs every Tempo component (`-target=all`) in one
# process: the distributor with OTLP receivers, the live store, the query
# frontend and querier, the backend scheduler and worker that compact
# blocks and apply retention, and, with `metricsGenerator.enabled`, the
# metrics generator. It keeps its write-ahead logs on the claim it gets
# through the `storage` dependency, and its trace blocks there too unless
# `objectStorage` moves them to an S3 bucket.
# The `<name>` Service serves the query API and metrics on 3200, and the
# `<name>-otlp` Service the OTLP receivers on 4317 (gRPC) and 4318 (HTTP).
# root = the `<name>` Service.
#
#   instances.tracing = {
#     storage = { package = packages.persistent-volume-claim; config.size = "20Gi"; };
#     tempo.package = packages.tempo;
#   };
#
# DI deps:
#   storage (required)           a persistent-volume-claim instance, mounted
#                                at /var/tempo
#   prometheus (optional)        ServiceMonitor on Tempo's /metrics
#   storageCredentials           a secret or secret-ref in this namespace
#                                with the S3 access key ID and secret key
#                                (keys `accessKeyId` and `secretAccessKey`,
#                                or those `objectStorage.credentialKeys`
#                                names), as stackgres-object-storage reads
#                                them. Required while `objectStorage` is set,
#                                and read only then. Tempo reads them from
#                                the AWS_ACCESS_KEY_ID and
#                                AWS_SECRET_ACCESS_KEY env vars. A secret
#                                instance rolls the pod when its content
#                                changes; a secret-ref does not.
#   endpointService (optional)   an S3 store in the cluster, as an instance
#                                whose root is its S3 Service. Read only
#                                while `objectStorage` is set: the package
#                                sets `storage.trace.s3.endpoint` to the
#                                Service's address and `insecure` from
#                                `objectStorage.endpointScheme`, and the
#                                derived policy opens it. No package has the
#                                alias, so wire it with
#                                deps.endpointService = ref.<ns>.<instance>.
#   prometheusServer (optional)  where the metrics generator writes, as an
#                                instance whose `out.remoteWriteUrl` takes
#                                Prometheus remote write
#                                (victoria-metrics-cluster). Required while
#                                `metricsGenerator.enabled`, and read only
#                                then. Grafana reads the same alias for its
#                                Prometheus datasource.
#
# Exposes (root.out, checked by kix.contracts.otlpEndpoint):
#   out.otlpGrpcUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4317"
#   out.otlpHttpUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4318"
#   out.tls          false
#   out.queryUrl     "http://<name>.<ns>.svc.<clusterDomain>:3200", the base
#                    of Tempo's query API, for a Grafana datasource
#
# `multitenancy_enabled` is locked to false, so senders and Grafana send no
# `X-Scope-OrgID` header. The instance answers `tempo` only. A sender's
# `otlp` dependency names it with `deps.otlp = ref.<ns>.<instance>`, or the
# cluster adds `aliases = [ "otlp" ]` to the instance.
#
# Object storage: with `objectStorage` set, Tempo writes blocks to
# `objectStorage.bucket` under the prefix `<namespace>/<instance>`
# (`settings.storage.trace.s3.prefix` changes it), so instances can share a
# bucket. The live store's write-ahead log stays on the claim. Without
# endpointService, `settings.storage.trace.s3.endpoint` names the store as
# `host[:port]` (`s3.<region>.amazonaws.com` for AWS S3), and the pod may
# open connections outside the cluster on that port, or on 443 (80 with
# `storage.trace.s3.insecure = true`) when it names none. An endpoint whose
# host ends in `.svc` or `.svc.<cluster domain>`, or is a single label, names
# a Service in the cluster and is refused; a `<service>.<namespace>` host
# cannot be told from a public domain and is not.
#
#   objectStorage.bucket = "traces";
#   settings.storage.trace.s3 = {
#     endpoint = "s3.eu-west-1.amazonaws.com";
#     region = "eu-west-1";
#   };
#
# Metrics generator: `metricsGenerator.enabled` turns on the span-metrics
# and service-graphs processors
# (`overrides.defaults.metrics_generator.processors`, which `settings` may
# replace) and remote-writes their series to the prometheusServer
# dependency's `out.remoteWriteUrl`. The generator keeps its write-ahead
# log on the claim.
#
# Escape hatches:
#   settings       Tempo's `tempo.yaml` keys, merged over `builtinConfig`
#                  below. A null removes an unlocked key, a list replaces
#                  the package's list whole, and the paths in `lockedPaths`
#                  fail evaluation. Size the claim for the ingest rate times
#                  `retention` while the blocks live on it.
#   extraArgs      flags after the package's own. The flags in `ownedFlags`
#                  fail evaluation: Tempo applies flags after the file, so
#                  each one would override a locked path.
#   env            container env, for `${NAME}` expansion in `settings`.
#   resources, partsOverlays, and each resource's `extra` for the rest.
#
# Limits: one replica (`meta.availability.max = "none"`) and a single
# tenant. `objectStorage` writes S3 with access keys only; IAM-role
# credentials, SSE-C customer keys, Azure, and Google Cloud Storage are not
# modelled. The
# generator writes to one remote-write target, without authentication. The
# package ships no alerts.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "tempo ${scope.namespaceName}/${name}";
  release = "3.1.0";

  httpPort = 3200;
  otlpGrpcPort = 4317;
  otlpHttpPort = 4318;
  dataPath = "/var/tempo";
  configDir = "/etc/tempo";

  # The grammar of Prometheus `model.ParseDuration`, which parses
  # `block_retention`: whole numbers, units from largest to smallest, each
  # unit once. At least one digit must be non-zero, because Tempo reads a
  # zero per-tenant retention as "use the compaction default" (14 days).
  durationType =
    lib.types.addCheck
      (lib.types.strMatching "([0-9]+y)?([0-9]+w)?([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?([0-9]+ms)?")
      (s: builtins.match ".*[1-9].*" s != null);

  # Tempo runs with `-config.expand-env=true`, and its envsubst reads `\\`
  # in the rendered JSON as an escape, so a backslash in a value breaks the
  # file. Returns the dotted paths of the strings that hold one.
  backslashPaths =
    path: v:
    if builtins.isString v then
      lib.optional (lib.hasInfix "\\" v) (lib.concatStringsSep "." path)
    else if builtins.isAttrs v then
      lib.concatLists (lib.mapAttrsToList (k: backslashPaths (path ++ [ k ])) v)
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: backslashPaths (path ++ [ "[${toString i}]" ])) v)
    else
      [ ];

  # `store` is null for the local backend, else `{ bucket; }`, with
  # `endpoint` and `insecure` added for an in-cluster store.
  # `remoteWriteUrl` is null while the metrics generator is off.
  builtinConfig =
    {
      retention,
      store,
      remoteWriteUrl,
    }:
    {
      target = "all";
      multitenancy_enabled = false;
      # The older spelling of multitenancy_enabled; true turns tenancy on.
      auth_enabled = false;
      http_api_prefix = "";
      # GOMEMLIMIT at 80% of the container's memory limit, so the Go runtime
      # collects garbage harder before the OOM killer acts.
      memory.automemlimit_enabled = true;
      server = {
        http_listen_port = httpPort;
        log_level = "info";
      };
      distributor.receivers.otlp.protocols = {
        # Every interface, so the Services reach the receivers.
        grpc.endpoint = "0.0.0.0:${toString otlpGrpcPort}";
        http.endpoint = "0.0.0.0:${toString otlpHttpPort}";
      };
      # In single-binary mode Tempo forces the live store's ring address to
      # 127.0.0.1 (cmd/tempo/main.go), so the querier's traffic stays in the pod.
      live_store = {
        wal.path = "${dataPath}/live-store/traces";
        shutdown_marker_dir = "${dataPath}/live-store/shutdown-marker";
      };
      backend_scheduler.local_work_path = "${dataPath}/backend-scheduler";
      storage.trace =
        if store == null then
          {
            backend = "local";
            local.path = "${dataPath}/blocks";
          }
        else
          {
            backend = "s3";
            # Each instance writes under its own prefix, so two instances
            # can share a bucket.
            s3 = store // {
              # A namespace name cannot hold `/`, so no two instances get
              # the same prefix.
              prefix = "${scope.namespaceName}/${name}";
            };
          };
      overrides.defaults = {
        compaction.block_retention = retention;
      }
      // lib.optionalAttrs (remoteWriteUrl != null) {
        metrics_generator.processors = [
          "service-graphs"
          "span-metrics"
        ];
      };
      usage_report.reporting_enabled = false;
    }
    // lib.optionalAttrs (remoteWriteUrl != null) {
      # In single-binary mode the distributor hands spans to the generator
      # in the same process (cmd/tempo/app/modules.go). A non-empty
      # `storage.path` is what turns the generator on.
      metrics_generator.storage = {
        path = "${dataPath}/generator/wal";
        remote_write = [ { url = remoteWriteUrl; } ];
      };
    };

  # metricsGenerator owns both: the path turns the generator on, and the
  # remote-write URL carries the dependency on the metrics store.
  generatorPaths = [
    [
      "metrics_generator"
      "storage"
      "path"
    ]
    [
      "metrics_generator"
      "storage"
      "remote_write"
    ]
  ];

  lockedPaths =
    {
      objectStorage,
      inClusterStore,
      metricsGenerator,
    }:
    [
      # `-target=all` is what makes the one pod serve every component.
      [ "target" ]
      # Consumers send no X-Scope-OrgID header.
      [ "multitenancy_enabled" ]
      [ "auth_enabled" ]
      # The Services, the probes, and `out` use these ports and paths.
      [ "http_api_prefix" ]
      [
        "server"
        "http_listen_port"
      ]
      [
        "distributor"
        "receivers"
        "otlp"
        "protocols"
        "grpc"
        "endpoint"
      ]
      [
        "distributor"
        "receivers"
        "otlp"
        "protocols"
        "http"
        "endpoint"
      ]
      # The claim is the only writable path that survives a restart. The live
      # store's write-ahead log, its shutdown marker, the backend scheduler's
      # job cache, and the local blocks live there.
      [
        "live_store"
        "wal"
        "path"
      ]
      [
        "live_store"
        "shutdown_marker_dir"
      ]
      [
        "backend_scheduler"
        "local_work_path"
      ]
      [
        "storage"
        "trace"
        "backend"
      ]
      [
        "storage"
        "trace"
        "local"
        "path"
      ]
      [
        "overrides"
        "defaults"
        "compaction"
        "block_retention"
      ]
    ]
    ++ lib.optionals metricsGenerator generatorPaths
    ++ lib.optional objectStorage [
      "storage"
      "trace"
      "s3"
      "bucket"
    ]
    # The endpointService dependency's address carries the store's network
    # policy, and endpointScheme sets `insecure`.
    ++ lib.optionals inClusterStore [
      [
        "storage"
        "trace"
        "s3"
        "endpoint"
      ]
      [
        "storage"
        "trace"
        "s3"
        "insecure"
      ]
    ];

  # Credential keys of Tempo's S3 client, under `storage.trace.s3`. A value
  # in `settings` would land in the ConfigMap, so they are refused whatever
  # the backend.
  s3CredentialPaths = [
    [ "access_key" ]
    [ "secret_key" ]
    [ "session_token" ]
    # The SSE-C customer key (tempodb/backend/s3/config.go).
    [
      "sse"
      "encryption_key"
    ]
  ];

  # The S3 credential selectors. Each reads the storageCredentials key of
  # its own name unless objectStorage.credentialKeys names another.
  credentialSelectors = [
    "accessKeyId"
    "secretAccessKey"
  ];

  # An S3 endpoint as Tempo reads it, `host[:port]`, as [ host _ port ], or
  # null.
  matchEndpoint = builtins.match "(\\[[^]]*]|[^]/:?#[]+)(:([0-9]+))?";

  # Tempo applies flags after the config file, so a flag that sets a locked
  # path overrides it. Go's flag package reads the `-` and `--` spellings.
  ownedFlags =
    let
      locks = path: "it sets ${path}, which the package locks; remove it.";
      secret =
        path:
        "it puts ${path}, a credential, on the command line; put the keys in the storageCredentials Secret and remove the flag.";
      flags = {
        "-config.file" = "the package renders the file from settings; change settings instead.";
        "-config.expand-env" = "settings and env rely on variable expansion; remove it.";
        "-target" = "the package runs every Tempo component in its one pod; remove it.";
        "-auth.enabled" = locks "auth_enabled";
        "-multitenancy.enabled" = locks "multitenancy_enabled";
        "-http-api-prefix" = locks "http_api_prefix";
        "-server.http-listen-port" = locks "server.http_listen_port";
        "-storage.trace.backend" = locks "storage.trace.backend";
        "-storage.trace.local.path" = locks "storage.trace.local.path";
        "-live-store.wal.path" = locks "live_store.wal.path";
        "-live-store.shutdown_marker_dir" = locks "live_store.shutdown_marker_dir";
        # Tempo 3.1.0 registers this flag with its prefix doubled.
        "-backend-schedulerbackend-scheduler.local-work-path" = locks "backend_scheduler.local_work_path";
        "-storage.trace.s3.bucket" =
          "it sets storage.trace.s3.bucket, which objectStorage.bucket owns; remove it.";
        "-storage.trace.s3.endpoint" =
          "it sets storage.trace.s3.endpoint, from which the package derives the store's network policy; set the endpoint in settings or wire endpointService, and remove the flag.";
        "-storage.trace.s3.access_key" = secret "storage.trace.s3.access_key";
        "-storage.trace.s3.secret_key" = secret "storage.trace.s3.secret_key";
        "-storage.trace.s3.session_token" = secret "storage.trace.s3.session_token";
        "-storage.trace.s3.sse.encryption-key" =
          "it puts storage.trace.s3.sse.encryption_key, a credential, on the command line, and the package has no way to pass an SSE-C key from a Secret; remove the flag.";
      };
    in
    flags // lib.mapAttrs' (flag: lib.nameValuePair "-${flag}") flags;
in
{
  meta = {
    version = release;
    description = "Grafana Tempo trace store, single binary on one volume";
    owner = "platform";
    defaultAliases = [ "tempo" ];
    # One process owns the volume (write-ahead logs, and blocks on the local
    # backend). A second replica would have no volume of its own.
    availability.max = "none";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/grafana/tempo";
      tag = release;
      digest = "sha256:3076b8dcdfb32fd6bc5ccef85e7b7313e6199b9cb84366257fc17ecb696db5fd";
    };

    retention = lib.mkOption {
      type = durationType;
      default = "168h";
      example = "720h";
      description = ''
        How long Tempo keeps a trace block, as a Prometheus duration: whole
        numbers with units `y`, `w`, `d`, `h`, `m`, `s`, and `ms`, largest
        first (`168h`, `7d`, `4w2d`). The default of seven days matches the
        loki package's, so a trace's links to its logs stay valid for as
        long as the trace. Rendered as
        `overrides.defaults.compaction.block_retention`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        query_frontend.search.max_duration = "336h";
      };
      description = ''
        Tempo configuration (`tempo.yaml` keys) merged over the package's
        own. A null removes a key the package sets. A list replaces the
        package's list whole. The package locks `target`,
        `multitenancy_enabled`, `auth_enabled`, `http_api_prefix`,
        `server.http_listen_port`, the OTLP receiver endpoints under
        `distributor.receivers.otlp.protocols`,
        `live_store.wal.path`, `live_store.shutdown_marker_dir`,
        `backend_scheduler.local_work_path`, `storage.trace.backend`,
        `storage.trace.local.path`,
        and `overrides.defaults.compaction.block_retention` (set
        `retention`). `metrics_generator.storage.path` and
        `metrics_generator.storage.remote_write` are refused; set
        `metricsGenerator.enabled`. With `objectStorage` set it also locks
        `storage.trace.s3.bucket`, and with an endpointService dependency
        `storage.trace.s3.endpoint` and `storage.trace.s3.insecure`. Setting
        one, or replacing a key above it, fails evaluation. The credential
        keys `storage.trace.s3.access_key`, `secret_key`, `session_token`,
        and `sse.encryption_key` are refused; the storageCredentials
        dependency supplies the access keys. While `metricsGenerator.enabled`
        is false, `overrides.defaults.metrics_generator.processors` is
        refused too.

        Tempo runs with `-config.expand-env=true`, so `''${NAME}` in a value
        reads the container's env var NAME (set it through `env`); an unset
        variable becomes an empty string. Write `$$` for a literal `$`.
        A backslash in a value is refused, because the expansion consumes it.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-log.level=debug" ];
      description = ''
        Flags appended after the package's own. Tempo applies flags after
        its config file, so the flags that would override a locked
        `settings` path (`-auth.enabled`, `-multitenancy.enabled`,
        `-http-api-prefix`, `-server.http-listen-port`,
        `-storage.trace.{backend,local.path}`,
        `-storage.trace.s3.{bucket,endpoint}`, and the live store and
        backend scheduler path flags), the S3 credential flags
        (`-storage.trace.s3.{access_key,secret_key,session_token}` and
        `-storage.trace.s3.sse.encryption-key`),
        `-config.file`, `-config.expand-env`, and `-target` fail evaluation.
      '';
    };

    env = kix.options.env;

    objectStorage = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            bucket = lib.mkOption {
              type = lib.types.strMatching "[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]";
              example = "traces";
              description = "The S3 bucket Tempo writes blocks to (`storage.trace.s3.bucket`). It must exist. Each instance writes under the prefix `<namespace>/<instance>` unless `settings.storage.trace.s3.prefix` names another.";
            };
            endpointScheme = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "http"
                  "https"
                ]
              );
              default = null;
              description = "Scheme of the endpointService dependency's Service: `https` sets `storage.trace.s3.insecure = false`. Null means `http`. Set only with an endpointService dependency; for a store that serves TLS with a private CA, also set `settings.storage.trace.s3.tls_ca_path` and mount the CA.";
            };
            credentialKeys = lib.genAttrs credentialSelectors (
              s:
              lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Key of the storageCredentials Secret holding `${s}`; null reads the key `${s}`.";
              }
            );
          };
        }
      );
      default = null;
      description = ''
        Trace blocks in an S3 bucket (`storage.trace.backend = "s3"`)
        instead of on the claim, which keeps the write-ahead logs. Non-null
        needs the storageCredentials dependency, and either an
        endpointService dependency or `settings.storage.trace.s3.endpoint`
        (`host[:port]`, no scheme). Other S3 settings, such as `region`,
        `forcepathstyle`, and `prefix`, go in `settings.storage.trace.s3`.
        Null keeps blocks on the claim.
      '';
    };

    metricsGenerator.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run Tempo's metrics generator with the `service-graphs` and
        `span-metrics` processors, writing their series by Prometheus
        remote write to the prometheusServer dependency's
        `out.remoteWriteUrl`. True needs that dependency.
        `settings.overrides.defaults.metrics_generator.processors` replaces
        the processor list.
      '';
    };

    # The live store holds up to 250 MB of live traces by default
    # (`live_store.max_live_traces_bytes`), and GOMEMLIMIT follows the limit.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        scope,
        kix,
        storage,
        storageCredentials ? null,
        endpointService ? null,
        prometheusServer ? null,
        ...
      }:
      let
        backslashes = backslashPaths [ "settings" ] config.settings;
        s3Settings = config.settings.storage.trace.s3 or { };
        inlineCredentials = builtins.filter (path: lib.hasAttrByPath path s3Settings) s3CredentialPaths;
        # Processors configured while the generator is off make Tempo fail
        # every push to the generator.
        generatorSettings = lib.optionals (!config.metricsGenerator.enabled) (
          builtins.filter (path: lib.hasAttrByPath path config.settings) (
            generatorPaths
            ++ [
              [
                "overrides"
                "defaults"
                "metrics_generator"
                "processors"
              ]
            ]
          )
        );
        settings =
          if backslashes != [ ] then
            throw "${who}: ${lib.concatStringsSep ", " backslashes} holds a backslash. Tempo expands environment variables in its config file and reads a backslash as an escape, which breaks the file. Remove the backslash from the value."
          else if generatorSettings != [ ] then
            throw "${who}: settings sets ${
              lib.concatMapStringsSep ", " (lib.concatStringsSep ".") generatorSettings
            }, which configures the metrics generator while metricsGenerator.enabled is false. Remove it, or set metricsGenerator.enabled = true, which runs the generator and writes to the prometheusServer dependency."
          else if inlineCredentials != [ ] then
            throw "${who}: settings sets ${
              lib.concatMapStringsSep ", " (
                path: lib.concatStringsSep "." ([ "storage.trace.s3" ] ++ path)
              ) inlineCredentials
            }, a credential that would land in the ConfigMap. Remove it. The package reads the S3 access keys from the storageCredentials dependency (a secret or secret-ref instance); it has no way to pass an SSE-C key from a Secret."
          else
            config.settings;

        os = config.objectStorage;
        objectStorageOn = os != null;
        inClusterStore = objectStorageOn && endpointService != null;

        credentialKeys = lib.genAttrs credentialSelectors (
          s: if os.credentialKeys.${s} != null then os.credentialKeys.${s} else s
        );
        credentials = kix.checkSecretKeys {
          inherit who;
          arg = "storageCredentials";
          dep =
            if storageCredentials == null then
              throw "${who}: objectStorage is set and no storageCredentials dependency resolved in namespace ${scope.namespaceName}. Add a secret or secret-ref instance there with the keys ${lib.concatStringsSep " and " (builtins.attrValues credentialKeys)} and the alias storageCredentials, or set objectStorage = null."
            else
              storageCredentials;
          keys = builtins.attrValues credentialKeys;
        };

        # Tempo's S3 client reads `host[:port]` and takes TLS from `insecure`.
        endpointScheme = if os.endpointScheme != null then os.endpointScheme else "http";
        store =
          if !objectStorageOn then
            if endpointService != null then
              throw "${who}: deps.endpointService is wired and objectStorage is null, so Tempo keeps its blocks on the claim and never reads the store. Set objectStorage.bucket, or remove deps.endpointService."
            else
              null
          else if inClusterStore then
            {
              inherit (os) bucket;
              endpoint = lib.removePrefix "${endpointScheme}://" (
                (endpointService.out.url
                  or (throw "${who}: deps.endpointService has no out.url. Wire an instance whose root is its S3 Service.")
                )
                  { scheme = endpointScheme; }
              );
              insecure = endpointScheme == "http";
            }
          else if os.endpointScheme != null then
            throw "${who}: objectStorage.endpointScheme is set and no endpointService dependency resolved, so nothing reads it. Wire the in-cluster store with deps.endpointService = ref.<namespace>.<instance>, or remove objectStorage.endpointScheme and set settings.storage.trace.s3.insecure for a store outside the cluster."
          else
            { inherit (os) bucket; };

        remoteWriteUrl =
          if !config.metricsGenerator.enabled then
            null
          else if prometheusServer == null then
            throw "${who}: metricsGenerator.enabled is true and no prometheusServer dependency resolved. Wire an instance that takes Prometheus remote write, such as a victoria-metrics-cluster, with deps.prometheusServer = ref.<namespace>.<instance>, or set metricsGenerator.enabled = false."
          else
            prometheusServer.out.remoteWriteUrl
              or (throw "${who}: deps.prometheusServer resolved to an instance without out.remoteWriteUrl, so the metrics generator has nowhere to write. The prometheus package does not take remote write. Wire a victoria-metrics-cluster instance with deps.prometheusServer = ref.<namespace>.<instance>, or set out.remoteWriteUrl in the kix.mkImport that answers prometheusServer.");

        mergedConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded
            {
              inherit who;
              what = "settings";
              locked = lockedPaths {
                objectStorage = objectStorageOn;
                inherit inClusterStore;
                metricsGenerator = config.metricsGenerator.enabled;
              };
            }
            (builtinConfig {
              inherit (config) retention;
              inherit store remoteWriteUrl;
            })
            settings
        );

        # The store's port outside the cluster; null for the local backend
        # and for an in-cluster store, whose address in the ConfigMap opens
        # the derived policy. A world egress rule does not reach pods, so an
        # endpoint that names a Service is refused.
        storeWorldPort =
          if !objectStorageOn || inClusterStore then
            null
          else
            let
              s3 = mergedConfig.storage.trace.s3;
              endpoint =
                s3.endpoint
                  or (throw "${who}: objectStorage is set with no endpointService dependency and no settings.storage.trace.s3.endpoint, and Tempo's S3 client has no default endpoint. Set settings.storage.trace.s3.endpoint to the store's host[:port] (s3.<region>.amazonaws.com for AWS S3), or wire a store in the cluster with deps.endpointService = ref.<namespace>.<instance>.");
              m = if builtins.isString endpoint then matchEndpoint endpoint else null;
              insecure = s3.insecure or false;
              host = lib.toLower (lib.removeSuffix "." (builtins.elemAt m 0));
              domain = lib.toLower clusterConfig.clusterDomain;
            in
            if m == null then
              throw "${who}: settings.storage.trace.s3.endpoint ${builtins.toJSON endpoint} is not host[:port]. Tempo's S3 client reads the address without a scheme and takes TLS from storage.trace.s3.insecure; write it as s3.example.com or s3.example.com:9000."
            else if !builtins.isBool insecure then
              throw "${who}: settings.storage.trace.s3.insecure is ${builtins.toJSON insecure}, and Tempo reads a boolean. Set it to true for a store that serves plain HTTP, or remove it."
            # A single-label host can only resolve inside the cluster, as a
            # Service short name. `<service>.<namespace>` cannot be told apart
            # from a public domain and passes.
            else if
              lib.hasSuffix ".svc" host
              || lib.hasSuffix ".svc.${domain}" host
              || (!lib.hasInfix "." host && !lib.hasPrefix "[" host)
            then
              throw "${who}: settings.storage.trace.s3.endpoint \"${endpoint}\" names a Service in the cluster, and the pod gets network policy only to stores outside it. Wire the store with deps.endpointService = ref.<namespace>.<instance> and remove the endpoint; set objectStorage.endpointScheme = \"https\" if it serves TLS."
            else if builtins.elemAt m 2 != null then
              lib.toInt (builtins.elemAt m 2)
            else if insecure then
              80
            else
              443;

        args = [
          "-config.file=${configDir}/tempo.yaml"
          "-config.expand-env=true"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = ownedFlags;
        } config.extraArgs;

        # Tempo's S3 client falls through its empty static keys to these
        # variables (tempodb/backend/s3/s3.go, fetchCreds), so the keys never
        # pass through the env expansion of the config file.
        env = kix.mergeEnv {
          inherit who;
          owned = lib.optional objectStorageOn {
            vars = {
              AWS_ACCESS_KEY_ID = credentials.out.keyRef credentialKeys.accessKeyId;
              AWS_SECRET_ACCESS_KEY = credentials.out.keyRef credentialKeys.secretAccessKey;
            };
            from = "the storageCredentials dependency";
            fix = "Remove those variables from env; the storageCredentials Secret supplies the keys.";
          };
        } config.env;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."tempo.yaml" = builtins.toJSON mergedConfig;
        };

        dataMount = kix.mount.pvc storage {
          name = "data";
          mountPath = dataPath;
        };
        configMount = kix.mount.configMap self.configMap {
          name = "config";
          mountPath = configDir;
          readOnly = true;
        };
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
          sizeLimit = "256Mi";
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
          extra.automountServiceAccountToken = false;
        };

        statefulSet =
          {
            inherit name;
            labels."app.kubernetes.io/name" = "tempo";
            spec = {
              headlessService = self.headlessService;
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                # The S3 keys are env vars, which Kubernetes sets only when the
                # container starts. A secret-ref has no content hash, so a
                # change to it does not roll the pod.
                metadata.annotations = {
                  "checksum/config" = self.configMap.out.identityHash;
                }
                // lib.optionalAttrs (objectStorageOn && credentials.out ? identityHash) {
                  "checksum/storage-credentials" = credentials.out.identityHash;
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  automountServiceAccountToken = false;
                  # Tempo's own HTTP and gRPC drain (`server.graceful_shutdown_timeout`)
                  # is 30 seconds. The live store replays its write-ahead
                  # log from the claim on the next start.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 10001;
                    runAsGroup = 10001;
                    fsGroup = 10001;
                    fsGroupChangePolicy = "OnRootMismatch";
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "tempo";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit args;
                      env = kix.mkEnvVars env;
                      # gRPC (9095) stays inside the pod.
                      ports = [
                        (kix.port "http" httpPort)
                        (kix.port "otlp-grpc" otlpGrpcPort)
                        (kix.port "otlp-http" otlpHttpPort)
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/ready";
                          port = "http";
                        };
                        initialDelaySeconds = 15;
                        periodSeconds = 10;
                      };
                      # /ready answers 503 until every component has
                      # started, and the live store replays its write-ahead
                      # log before it starts, so liveness only asks whether
                      # the port is open.
                      livenessProbe = {
                        tcpSocket.port = "http";
                        periodSeconds = 20;
                        failureThreshold = 6;
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            self.dataMount
            self.configMount
            self.tmpMount
          ]
          |> scope.mkStatefulSet;

        # Governs the StatefulSet's pod DNS; nothing dials it. The component
        # label keeps its labels distinct from the client Service's.
        headlessService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-headless";
            labels."app.kubernetes.io/component" = "headless";
            spec.clusterIP = "None";
          }
          |> scope.mkResource;

        # Two client Services, so a query client (Grafana) gets egress to
        # the query port only and a sender to the OTLP ports only.
        service =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "query";
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
              }
            ];
          }
          |> scope.mkResource;

        otlpService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-otlp";
            labels."app.kubernetes.io/component" = "otlp";
            ports = [
              {
                name = "otlp-grpc";
                port = otlpGrpcPort;
                targetPort = "otlp-grpc";
                appProtocol = "grpc";
              }
              {
                name = "otlp-http";
                port = otlpHttpPort;
                targetPort = "otlp-http";
              }
            ];
          }
          |> scope.mkResource;

        # Egress outside the cluster to the S3 store; see storeWorldPort.
        storeEgress =
          if storeWorldPort == null then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-object-storage";
              spec = scope.networkPolicyEnforcer.netpol.mkEndpointSelector scope.selectorLabels // {
                egress =
                  (scope.networkPolicyEnforcer.netpol.translateIntentRules {
                    intents.store.egress = [
                      {
                        to = "world";
                        ports = [
                          {
                            port = storeWorldPort;
                            protocol = "TCP";
                          }
                        ];
                      }
                    ];
                  }).egressRules;
              };
            };

        root = {
          resource = self.service;
          # Listing the monitoring parts keeps them referenced from root.
          requires = builtins.filter (part: part != null) [
            self.storeEgress
            self.serviceMonitor
            self.prometheusRules
          ];
          out = kix.contracts.otlpEndpoint.check who {
            otlpGrpcUrl = self.otlpService.out.url { port = otlpGrpcPort; };
            otlpHttpUrl = self.otlpService.out.url { port = otlpHttpPort; };
            tls = false;
            queryUrl = self.service.out.url { port = httpPort; };
          };
        };
      }
    )

    (kix.monitor {
      service = "service";
      port = "http";
    })
  ];
}
