# Options of the tempo package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  release,
  credentialSelectors,
}:
let
  # Prometheus `model.ParseDuration` grammar, with at least one non-zero digit
  # because Tempo treats a zero per-tenant retention as "use the compaction
  # default" (14 days).
  durationType =
    lib.types.addCheck
      (lib.types.strMatching "([0-9]+y)?([0-9]+w)?([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?([0-9]+ms)?")
      (s: builtins.match ".*[1-9].*" s != null);
in
{
  image = kix.options.image {
    repository = "docker.io/grafana/tempo";
    tag = release;
    digest = "sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044";
  };

  retention = lib.mkOption {
    type = durationType;
    default = "168h";
    example = "720h";
    description = ''
      How long Tempo keeps a trace block, as a Prometheus duration (`y`, `w`,
      `d`, `h`, `m`, `s`, and `ms`, largest first). Rendered as
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
      defaults. A null removes a key; a list replaces a default list. The
      package locks `target`, `multitenancy_enabled`, `auth_enabled`,
      `http_api_prefix`, `server.http_listen_port`, the OTLP receiver endpoints
      under `distributor.receivers.otlp.protocols`, `live_store.wal.path`,
      `live_store.shutdown_marker_dir`, `backend_scheduler.local_work_path`,
      `storage.trace.backend`, `storage.trace.local.path`, and
      `overrides.defaults.compaction.block_retention` (set `retention`).
      `metrics_generator.storage.path` and
      `metrics_generator.storage.remote_write` are refused (set
      `metricsGenerator.enabled`). With `objectStorage` set, it also locks
      `storage.trace.s3.bucket`, and with `endpointService`,
      `storage.trace.s3.endpoint` and `storage.trace.s3.insecure`. S3
      credential keys (`access_key`, `secret_key`, `session_token`, and
      `sse.encryption_key`) are refused; wire `storageCredentials` instead.
      When `metricsGenerator.enabled` is false,
      `overrides.defaults.metrics_generator.processors` is also refused.

      Tempo runs with `-config.expand-env=true`, so `''${NAME}` expands the
      container environment variable `NAME` (write `$$` for a literal `$`).
      Backslashes in values are refused because variable expansion consumes
      them.
    '';
  };

  extraArgs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "-log.level=debug" ];
    description = ''
      Flags appended after the package's own. Flags that override locked
      `settings` paths, S3 credential flags, `-config.file`,
      `-config.expand-env`, and `-target` fail evaluation.
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
            description = "The S3 bucket Tempo writes blocks to (`storage.trace.s3.bucket`). Each instance writes under `<namespace>/<instance>` unless `settings.storage.trace.s3.prefix` overrides it.";
          };
          endpointScheme = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "http"
                "https"
              ]
            );
            default = null;
            description = "Scheme of the `endpointService` dependency's Service (`https` sets `storage.trace.s3.insecure = false`; null means `http`). Set only with an `endpointService` dependency.";
          };
          credentialKeys = lib.genAttrs credentialSelectors (
            s:
            lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Key of the `storageCredentials` Secret holding `${s}`; null reads `${s}`. Refused when `storageCredentials` is an IAM role.";
            }
          );
        };
      }
    );
    default = null;
    description = ''
      Store trace blocks in an S3 bucket (`storage.trace.backend = "s3"`)
      instead of on the claim, which keeps the write-ahead logs. Requires the
      `storageCredentials` dependency and either `endpointService` or
      `settings.storage.trace.s3.endpoint` (`host[:port]`, no scheme).
      `storageCredentials` is a Secret with the S3 keys, or, for a store
      outside the cluster such as AWS S3, an IAM role:
      `deps.storageCredentials = kix.cloudIdentity.aws { roleArn = "..."; }`.
    '';
  };

  metricsGenerator.enabled = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run Tempo's metrics generator with the `service-graphs` and
      `span-metrics` processors, writing series via Prometheus remote write to
      the `prometheusServer` dependency's `out.remoteWriteUrl`.
    '';
  };

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

  metrics = kix.options.monitor // {
    requestErrorRatio = lib.mkOption {
      type = lib.types.numbers.between 0 1;
      default = 0.1;
      example = 0.05;
      description = "Share of a route's HTTP requests that may answer 5xx before `TempoRequestErrors` fires.";
    };
    requestErrorMinRate = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      default = 0.1;
      example = 1;
      description = "Minimum requests per second a route must serve before `TempoRequestErrors` evaluates its error ratio.";
    };
  };
}
