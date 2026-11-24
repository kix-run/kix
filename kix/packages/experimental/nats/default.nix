# nats: NATS, a messaging server, with JetStream persistence, as one
# StatefulSet on the official image.
#
# Installs the StatefulSet with a volume per pod for JetStream, a client
# Service on port 4222, a monitoring Service on port 8222, a headless
# Service for the pods' stable names and the cluster routes on port 6222,
# and a ConfigMap holding nats.conf. One replica runs a single server; more
# than one runs a NATS cluster whose servers route to each other.
#
# Dependencies:
#   natsAuth (required)       a `secret` or `secret-ref` in this namespace
#                             with keys `username` and `password`. Every
#                             client logs in as that user.
#   storageClasses (optional) the class of the JetStream volumes when
#                             `storage.storageClassName` is null.
#   prometheus (optional)     a metrics Service, a ServiceMonitor, and
#                             alerts while `metrics.enabled`.
#
# Minimal instance:
#
#   instances.messaging = {
#     nats.package = packages.experimental.nats;
#     nats-auth = {
#       package = packages.secret;
#       aliases = [ "natsAuth" ];
#       config = { source = ./secrets/nats-auth.sops.yaml; keys = [ "username" "password" ]; };
#     };
#   };
#
# A consumer takes the instance as its `nats` dependency and reads `out`:
#
#   env = kix.mkEnvVars {
#     NATS_URL = nats.out.url;
#     NATS_USER = nats.out.credentials.out.keyRef "username";
#     NATS_PASSWORD = nats.out.credentials.out.keyRef "password";
#   };
#
# A consumer in another namespace names the instance with
# `deps.nats = ref.<namespace>.<instance>` and reads the address from
# `out`. A Secret reference resolves only in the pod's own namespace, so it
# logs in with a secret of its own namespace that holds the same login;
# reading `out.credentials` from there fails evaluation.
# clusters/test-nats.nix evaluates these forms.
#
# Mode: `clustered` chooses between one standalone server (the default)
# and a NATS cluster of `replicas` servers (default 3, odd, at least 3).
# The availability level never sets it, because NATS cannot move a
# JetStream server between the two modes in place (Limits). Instead the
# build refuses a level that disagrees with the mode: standalone at `pod`
# and above, clustered at `none`. The refusal names both ways forward:
# pin the instance's own level with `instances.<ns>.<name>.availability`,
# or back up the streams, switch, and restore them. Kix by itself does not
# refuse more than one replica at level `none`; only a package or builder
# ceiling of `none` does. `replicas` is an option because a cluster of 5
# tolerates two lost servers. Clustered JetStream keeps its metadata and
# replicated streams in Raft groups that need a majority of servers, so an
# even count is refused: it adds a server without letting the cluster lose
# one more. A stream gets copies on several servers only when its client
# creates it with more than one replica (`nats stream add --replicas 3`);
# a stream with one replica lives on one server's volume and is
# unavailable while that pod restarts.
#
# Configuration: nats.conf is rendered as JSON, which the NATS config
# parser reads. The server name is the pod name and the cluster name is the
# instance name. `settings` is merged over the package's keys.
# `jetstream.max_file_store` defaults to `storage.size` and
# `jetstream.max_memory_store` to 0, as in upstream's Helm chart, so memory
# streams are refused until `settings.jetstream.max_memory_store` gives
# them room. Upstream documents no headroom between max_file_store and the
# volume size. GOMEMLIMIT defaults to 80% of `resources.limits.memory`, the
# share upstream's chart README recommends. The default resources (500m
# CPU, 1Gi memory) are a development size; the chart README recommends at
# least 2 CPU and 8Gi for a production JetStream cluster.
#
# Auth: nats.conf names the user and password as the environment variables
# NATS_USER and NATS_PASSWORD, and the server reads them from the natsAuth
# Secret at start, so the login stays out of the ConfigMap. The routes
# between servers and the monitoring port take no credentials.
#
# Shutdown: a preStop hook puts the server into lame duck mode
# (runLameDuckMode in server/server.go). It stops accepting clients, moves
# its Raft leaders to other servers, waits the 10-second grace period, and
# then closes its clients one at a time over the rest of the 30-second
# duration, so they reconnect to another server. terminationGracePeriodSeconds
# is 60, the grace period plus the duration plus 20 seconds, as upstream's
# chart sets it, which leaves room beyond the 30 seconds lame duck mode takes.
#
# Health: the probes are upstream's chart probes on the monitoring port. The
# startup probe allows up to 15 minutes for /healthz, which in a cluster
# also needs the JetStream metadata leader and the streams to have caught
# up. Readiness reads /healthz?js-server-only=true and liveness
# /healthz?js-enabled-only=true, so a server whose streams lag stays in
# the Services and is not restarted. With `healthCheck.enabled`, a Job
# after each deploy connects through the client Service, publishes a
# message and reads it back, asks the JetStream API for the account's
# limits, and checks that an anonymous client is refused.
#
# Network policy: a consumer that reads `out.url` or `out.host` gets the
# client port, 4222, and one that reads `out.monitoringHost` gets the
# monitoring port, 8222, because each comes from its own Service. That
# holds for a consumer in another namespace, and for the pods a custom
# resource's definition names in `factBehavior` when the resource carries
# the address. The pods of an instance reach each other on every port,
# which covers the routes. The exporter reads the monitoring port over
# localhost.
#
# Metrics: with `metrics.enabled` each pod runs upstream's
# prometheus-nats-exporter as a sidecar on port 7777, reading the
# monitoring port with the flags of upstream's chart plus -healthz. The
# sidecar follows `metrics.enabled` alone, so adding a prometheus
# dependency does not restart the pods. Alerts, scoped to the instance's
# metrics Service:
#   NATSMetricsAbsent (critical)     no exporter has read a server for 5
#                                    minutes.
#   NATSServerUnhealthy (warning)    a server's /healthz has failed for 10
#                                    minutes: JetStream has no metadata
#                                    leader, or a stream or consumer has
#                                    not recovered or caught up.
#   NATSJetStreamStorageNearLimit (warning, with JetStream)
#                                    a server's JetStream files fill over
#                                    90% of max_file_store, past which
#                                    publishes to file streams fail.
#   NATSConnectionsNearLimit (warning)
#                                    a server holds over 90% of
#                                    max_connections, past which it refuses
#                                    clients.
#   NATSSlowConsumers (warning)      a server dropped messages for a client
#                                    that read too slowly.
# No alert counts routes: /routez counts every pooled and pinned route
# connection (8 between three servers with the default pool of 3), so a
# lost peer does not show as fewer routes than `replicas - 1`. A cluster
# that loses its metadata leader fails /healthz instead. Pods that crash or
# do not become ready are left to the cluster's generic rules.
#
# `out`:
#   out.host, out.port      the client Service and its port, "4222".
#   out.url                 nats://<out.host>:4222, for a client's server
#                           list.
#   out.monitoringHost, out.monitoringPort
#                           the monitoring Service and its port, "8222",
#                           for a poller such as KEDA's NATS JetStream
#                           scaler.
#   out.credentials         the natsAuth secret (keys `username` and
#                           `password`), for consumers in this namespace.
#   out.jetstream           whether JetStream is on.
#   out.version             the NATS version `image.tag` names.
#
# Escape hatches: `settings` (nats.conf keys, refusing those the package
# writes or does not support, under every spelling server/opts.go accepts,
# and the other spellings of keys it leaves to the user; settings.nix
# lists them), and `env` on the nats container, refusing the variables the
# package sets (POD_NAME, NATS_USER, NATS_PASSWORD, AUTH_USER, and
# AUTH_PASSWORD).
#
# Limits:
#   - Switching `clustered` on an instance that holds data loses its
#     JetStream streams, which is why the mode is a choice of its own.
#     Switched on, the servers start clustered, and nats-0 marks the
#     streams it stored as orphaned and deletes them about 30 seconds after
#     it starts. Switched off, nats-0 starts standalone, refuses to recover
#     any stream with more than one replica, and fails /healthz, so the pod
#     never becomes ready; the files stay on the volumes, and streams with
#     one replica on nats-1 and nats-2 stay on their retained claims. Both
#     were observed with nats-server 2.15.3, and a server with a cluster
#     block and no peer never starts JetStream (server/raft.go waits for a
#     route), so one clustered server is no way around it. Back up streams
#     (`nats stream backup`) before switching, and restore them after.
#   - Scaling a JetStream cluster down leaves the removed servers in the
#     metadata group until `nats server raft peer-remove` removes each.
#   - Kix waits at most five minutes for a resource to become ready, so a
#     server that needs more of its 15-minute startup budget, or a slow
#     roll of many servers, fails the deploy.
#   - The routes on port 6222 take no credentials, as in upstream's chart.
#     Network policy admits only the instance's own pods there; on a
#     cluster without an enforcer, any pod can join the cluster as a route
#     and read every message.
#   - The monitoring port 8222 takes no credentials and serves subjects,
#     client addresses, and connection names (/connz, /subsz). Network
#     policy admits only the pods that depend on it.
#   - No system account user is configured, so `nats server list`,
#     `nats server report`, and `nats server raft peer-remove` are refused;
#     read the monitoring endpoints instead.
#   - The password must not contain a single quote (the package hands it to
#     the config parser as a single-quoted string) and is used as written,
#     so a trailing newline in the Secret is part of it. NATS treats a
#     password shaped like a bcrypt hash (`$2a$10$...`, also `$2b$`, `$2x$`,
#     and `$2y$`) as one (isBcrypt in server/auth.go).
#   - After a downgrade, an older server reports streams and consumers that
#     use a newer JetStream API level as offline and does not serve them
#     (DowngradeStreamTest in server/jetstream_cluster_1_test.go).
#   - A restart of a server loses the messages of core NATS subscriptions
#     in flight to its clients; JetStream keeps what streams store.
#   - Client TLS, accounts, JWT auth, leaf nodes, gateways, WebSocket, and
#     MQTT are not supported.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "v2.15.3";

  name = scope.instanceName;
  who = "nats ${scope.namespaceName}/${name}";

  ports = {
    client = 4222;
    cluster = 6222;
    monitor = 8222;
    metrics = 7777;
  };

  storeDir = "/data";
  pidFile = "/var/run/nats/nats.pid";

  settingsCheck = import ./settings.nix { inherit lib; };

  hardening = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };

  healthz = query: {
    httpGet = {
      path = "/healthz${query}";
      port = ports.monitor;
    };
  };

  # Values in nats.conf that the server reads from its environment. The
  # renderer writes each without quotes, which is how NATS marks a variable
  # reference (conf/parse.go).
  envRefs = [
    "POD_NAME"
    "NATS_USER"
    "NATS_PASSWORD"
  ];
  ref = var: "\$${var}";
  render =
    conf:
    builtins.replaceStrings (map (v: builtins.toJSON (ref v)) envRefs) (map ref envRefs) (
      builtins.toJSON conf
    );
in
{
  meta = {
    version = release;
    description = "Standalone or clustered NATS messaging server with JetStream persistence";
    owner = "platform";
    lifecycle = "stateful";
    # No `scope`: a consumer in this namespace finds the instance by its
    # alias, and one in another namespace names it with
    # `deps.nats = ref.<namespace>.<instance>`.
    defaultAliases = [ "nats" ];
  };

  # The mode is a choice the cluster author makes, because NATS cannot
  # move a JetStream server between standalone and clustered in place
  # (verified with nats-server 2.15.3; see Limits). The availability level
  # never sets it, and a level that disagrees with it is refused.
  assertions =
    { config, ... }:
    let
      multi = kix.availability.atLeast "pod" availability;
      n = config.replicas;
    in
    [
      {
        assertion = config.clustered || !multi;
        option = "clustered";
        message = "`clustered` is `false` (1 standalone server), which conflicts with availability level `${availability}` (multiple replicas). Kix stopped before deploying anything, so any running instance and its JetStream data are unchanged. Kix never turns on `clustered` automatically because NATS cannot convert a standalone JetStream server to a cluster in place. In `nats-server` 2.15.3, a standalone server restarted in clustered mode marks its stored streams as orphaned and deletes them about 30 seconds after startup.";
        fix = "To keep one standalone server, set `instances.${scope.namespaceName}.${name}.availability = \"none\";`. For a new instance with no data, set `instances.${scope.namespaceName}.${name}.config.clustered = true;`. To migrate an existing instance with data, back up every stream with `nats stream backup`, set `instances.${scope.namespaceName}.${name}.config.clustered = true;`, deploy, and restore the streams with `nats stream restore`.";
      }
      {
        assertion = !config.clustered || multi;
        option = "clustered";
        message = "`clustered` is `true` (3 or more servers), which conflicts with availability level `none` (1 replica). Kix stopped before deploying anything, so any running instance and its JetStream data are unchanged. NATS cannot convert a JetStream cluster to a standalone server in place. In `nats-server` 2.15.3, a cluster shrunk to one standalone server refuses to recover multi-replica streams and fails `/healthz`, so its pod never becomes ready (stream files remain on the volumes).";
        fix = "To run a NATS cluster, set `instances.${scope.namespaceName}.${name}.availability = \"pod\";` (or `\"node\"` or `\"zone\"`), or raise `cluster.availability.default`. For a new standalone server with no data, set `instances.${scope.namespaceName}.${name}.config.clustered = false;`. To switch an existing cluster with data to a standalone server, back up every stream with `nats stream backup`, set `instances.${scope.namespaceName}.${name}.config.clustered = false;`, deploy, and restore the streams with `nats stream restore`.";
      }
      {
        assertion = config.clustered || n == 1;
        option = "replicas";
        message = "`replicas` is ${toString n}, which is invalid when `clustered` is `false` (standalone mode runs 1 pod). Kix stopped before deploying anything.";
        fix = "To run one standalone server, remove `replicas` or set `replicas = 1;`. To run a NATS cluster, set `clustered = true;` with an availability level of `pod`, `node`, or `zone`. Switching an existing standalone instance in place deletes its stored streams: if it holds data, back up every stream with `nats stream backup` first and restore them with `nats stream restore` after deploying.";
      }
      {
        assertion = !config.clustered || (n >= 3 && lib.mod n 2 == 1);
        option = "replicas";
        message = "`replicas` is ${toString n}, but `clustered = true` requires an odd number of at least 3. JetStream requires a majority quorum, and an even server count tolerates no more failures than the next lower odd count. Kix stopped before deploying anything.";
        fix = "Set `replicas` to an odd number of 3 or more, such as 3 or 5.";
      }
    ];

  config =
    { config, ... }:
    {
      replicas = lib.mkDefault (if config.clustered then 3 else 1);
    };

  options = {
    image = kix.options.image {
      repository = "docker.io/library/nats";
      tag = "${lib.removePrefix "v" release}-alpine";
      digest = "sha256:558394a23dd3c36f2d3a64b51865fd09908010e80a542cea5e75c2af543ed62a";
      description = "Container image for `nats-server`.";
    };

    clustered = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run a NATS cluster of `replicas` servers (`true`) or one standalone server (`false`). The availability level never sets `clustered` automatically: Kix rejects `false` at `pod`, `node`, or `zone`, and rejects `true` at `none`. NATS cannot switch an instance with data between standalone and clustered modes in place without deleting or stranding JetStream streams. Back up every stream with `nats stream backup` first, change `clustered` and deploy, then restore them with `nats stream restore`.";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      defaultText = lib.literalMD "`3` when `clustered` is `true`, otherwise `1`";
      description = "Number of NATS server pods. Must be `1` when `clustered` is `false`, and an odd number of at least `3` when `clustered` is `true`.";
    };

    jetstream.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable JetStream persistence. When `true`, each pod mounts a PersistentVolumeClaim at `/data` for stream and consumer state. When `false`, the StatefulSet creates no volumes and serves core NATS (in-memory publish/subscribe) only.";
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "10Gi";
        description = "Size of each pod's `/data` PersistentVolumeClaim when JetStream is enabled. Also sets the default `settings.jetstream.max_file_store`. Kubernetes does not allow changing a StatefulSet's `volumeClaimTemplates` in place, and existing claims keep their original size.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass for each pod's JetStream volume. When `null`, Kix uses the cluster's `storageClasses` provider if configured, or falls back to the cluster's default StorageClass.";
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        max_payload = 8388608;
        jetstream.max_memory_store = 1073741824;
      };
      description = "Extra `nats.conf` settings merged over this package's defaults. Keys in `settings`, `settings.cluster`, and `settings.jetstream` must be lowercase. When NATS accepts multiple names for a setting (such as `max_file_store` and `max_file`), use the canonical name (`max_file_store`). Kix rejects settings that this package manages or does not support: ports and listen addresses, `server_name`, `pid_file`, lame duck timings, `ports_file_dir`, log files and syslog, the profiling port, client TLS, `authorization`, `accounts`, JWT authentication, leaf nodes, gateways, WebSocket, and MQTT. `settings.cluster` is allowed only when `clustered` is `true`, and rejects `name`, `port`, `listen`, `host`, `net`, `routes`, `authorization`, and `tls`. `settings.jetstream` is allowed only when `jetstream.enabled` is `true`, and rejects `store_dir`, `enabled`, and encryption settings (`key`, `prev_key`, `cipher`, and `tpm`).";
    };

    env = kix.options.env // {
      description = "Extra environment variables for the `nats` container. `GOMEMLIMIT` defaults to 80% of `resources.limits.memory` and can be overridden here. Kix rejects `POD_NAME`, `NATS_USER`, `NATS_PASSWORD`, `AUTH_USER`, and `AUTH_PASSWORD`, which this package sets automatically.";
    };

    # Upstream's chart README recommends equal requests and limits for CPU
    # and memory, so the Go runtime sizes GOMAXPROCS from the CPU limit and
    # the pod is in the Guaranteed QoS class.
    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "1Gi";
      };
      limits = {
        cpu = "500m";
        memory = "1Gi";
      };
      description = "CPU and memory requests and limits for the `nats` container. The defaults (`500m` CPU and `1Gi` memory) are sized for development. For production JetStream clusters, upstream NATS recommends equal requests and limits of at least `2` CPU and `8Gi` memory. `limits.memory` also sets the default `GOMEMLIMIT` (80% of the limit).";
    };

    metrics = kix.options.monitor // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the `prometheus-nats-exporter` sidecar in each pod. When the cluster also has a `prometheus` provider, Kix creates a metrics Service, a ServiceMonitor, and Prometheus alert rules. Changing `metrics.enabled` restarts the pods; adding or removing a `prometheus` provider does not.";
      };
      image = kix.options.image {
        repository = "docker.io/natsio/prometheus-nats-exporter";
        tag = "0.20.3";
        digest = "sha256:4b8ddc1c86fec360b5cd3d5e1fbc6fb52bdafd5805bba3901cc52926538af255";
        description = "Container image for the `prometheus-nats-exporter` sidecar.";
      };
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
    };

    healthCheck = kix.options.healthCheck // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a post-deploy Job that verifies the NATS instance through its client Service. The Job logs in, publishes and reads back a test message, queries JetStream account info when `jetstream.enabled` is `true`, and confirms that unauthenticated connections are rejected.";
      };
    };
  };

  build = [
    (
      {
        self,
        config,
        natsAuth,
        storageClasses ? null,
        prometheus ? null,
        ...
      }:
      let
        inherit (config) clustered;
        jetstream = config.jetstream.enabled;
        scrape = config.metrics.enabled && prometheus != null;

        auth = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "natsAuth";
          dep = natsAuth;
          keys = [
            "username"
            "password"
          ];
        };

        storageClassName =
          if config.storage.storageClassName != null then
            config.storage.storageClassName
          else if storageClasses != null then
            storageClasses.out.storageClassName
          else
            null;

        memoryLimit = config.resources.limits.memory or null;

        settingsProblems = settingsCheck.problems {
          inherit ports clustered jetstream;
        } config.settings;

        # The pods are named `<StatefulSet>-<ordinal>`. The ConfigMap cannot
        # read the StatefulSet's `out.name`, because the StatefulSet mounts
        # the ConfigMap, so the routes use the instance name the
        # StatefulSet is given below.
        routes = map (
          i: "nats://${name}-${toString i}.${self.headlessService.out.fqdn}:${toString ports.cluster}"
        ) (lib.range 0 (config.replicas - 1));

        packageConf = {
          server_name = ref "POD_NAME";
          port = ports.client;
          http_port = ports.monitor;
          pid_file = pidFile;
          lame_duck_grace_period = "10s";
          lame_duck_duration = "30s";
        }
        // lib.optionalAttrs clustered {
          cluster = {
            inherit name;
            port = ports.cluster;
            # Clients learn other servers from the client Service, not from
            # the pod addresses the servers would advertise.
            no_advertise = true;
            inherit routes;
          };
        }
        // lib.optionalAttrs jetstream {
          jetstream = {
            store_dir = storeDir;
            max_file_store = kix.parseQuantity "storage" config.storage.size;
            max_memory_store = 0;
          };
        }
        // {
          authorization = {
            user = ref "NATS_USER";
            password = ref "NATS_PASSWORD";
          };
        };

        natsConf =
          if settingsProblems != [ ] then
            scope.fail settingsProblems
          else
            render (lib.recursiveUpdate packageConf config.settings);

        # The config parser reads a variable's value as config text, so a
        # bare password could parse as a number or a nested reference. The
        # single quotes make it a string the parser does not interpret.
        # Kubernetes expands $(VAR) only from variables earlier in the list,
        # so the raw values come first.
        authRaw = kix.mkEnvVars {
          AUTH_USER = auth.out.keyRef "username";
          AUTH_PASSWORD = auth.out.keyRef "password";
        };

        natsEnv =
          authRaw
          ++ kix.mkEnvVars (
            kix.mergeEnv {
              inherit scope;
              defaults = lib.optionalAttrs (memoryLimit != null) {
                GOMEMLIMIT = toString (kix.parseQuantity "memory" memoryLimit * 8 / 10);
              };
              owned = [
                {
                  vars.POD_NAME.valueFrom.fieldRef.fieldPath = "metadata.name";
                  from = "the pod's `metadata.name` so each server is named after its pod";
                }
                {
                  vars = {
                    NATS_USER = "'$(AUTH_USER)'";
                    NATS_PASSWORD = "'$(AUTH_PASSWORD)'";
                  };
                  names = [
                    "AUTH_USER"
                    "AUTH_PASSWORD"
                  ];
                  from = "the `natsAuth` dependency";
                  fix = "Remove credential variables from `env`. Set `username` and `password` in the `natsAuth` secret, or point `deps.natsAuth` at another secret.";
                }
              ];
            } config.env
          );

        configMount = kix.mount.configMap self.configMap {
          name = "config";
          mountPath = "/etc/nats-config";
          readOnly = true;
        };

        natsContainer = {
          name = "nats";
          image = kix.image.ref config.image;
          imagePullPolicy = config.image.pullPolicy;
          args = [
            "--config"
            "${configMount.mountPath}/nats.conf"
          ];
          ports = [
            (kix.port "nats" ports.client)
            (kix.port "monitor" ports.monitor)
          ]
          ++ lib.optional clustered (kix.port "cluster" ports.cluster);
          env = natsEnv;
          inherit (config) resources;
          lifecycle.preStop.exec.command = [
            "nats-server"
            "--signal"
            "ldm=${pidFile}"
          ];
          # Upstream's chart probes.
          startupProbe = healthz "" // {
            initialDelaySeconds = 10;
            timeoutSeconds = 5;
            periodSeconds = 10;
            failureThreshold = 90;
          };
          readinessProbe = healthz "?js-server-only=true" // {
            initialDelaySeconds = 10;
            timeoutSeconds = 5;
            periodSeconds = 10;
            failureThreshold = 3;
          };
          livenessProbe = healthz "?js-enabled-only=true" // {
            initialDelaySeconds = 10;
            timeoutSeconds = 5;
            periodSeconds = 30;
            failureThreshold = 3;
          };
          securityContext = hardening;
          # The claim template's volume; the StatefulSet declares it.
          volumeMounts = lib.optional jetstream {
            name = "data";
            mountPath = storeDir;
          };
        };

        # The flags of upstream's chart, plus -healthz for the
        # NATSServerUnhealthy alert.
        exporterArgs = [
          "-port=${toString ports.metrics}"
          "-connz"
          "-routez"
          "-subz"
          "-varz"
          "-healthz"
          "-prefix=nats"
          "-use_internal_server_id"
        ]
        ++ lib.optional jetstream "-jsz=all"
        ++ [ "http://localhost:${toString ports.monitor}/" ];

        metricsContainer = {
          name = "metrics";
          image = kix.image.ref config.metrics.image;
          imagePullPolicy = config.metrics.image.pullPolicy;
          args = exporterArgs;
          ports = [ (kix.port "metrics" ports.metrics) ];
          inherit (config.metrics) resources;
          # The exporter serves only its scrape path, and a request to it
          # reads the server, so the probes check the listener.
          livenessProbe.tcpSocket.port = ports.metrics;
          readinessProbe.tcpSocket.port = ports.metrics;
          # Give the exporter 60 seconds to open port 7777 before liveness checks start.
          # With -use_internal_server_id, it fetches /varz before listening and waits
          # 30 seconds to retry when NATS is not up yet. This covers one retry with room
          # to spare so liveness does not kill the container after 30 seconds.
          startupProbe = {
            tcpSocket.port = ports.metrics;
            periodSeconds = 10;
            failureThreshold = 6;
          };
          securityContext = hardening;
        };

        headlessPorts = [
          {
            name = "nats";
            port = ports.client;
            targetPort = ports.client;
            protocol = "TCP";
          }
        ]
        ++ lib.optional clustered {
          name = "cluster";
          port = ports.cluster;
          targetPort = ports.cluster;
          protocol = "TCP";
        };
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."nats.conf" = natsConf;
        };

        statefulSet =
          {
            inherit name;
            spec = {
              headlessService = self.headlessService;
              inherit (config) replicas;
              # Upstream's chart starts every pod at once. Each server's
              # routes name every pod, and a cluster forms as they come up.
              podManagementPolicy = "Parallel";
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations = {
                  "checksum/configMap" = self.configMap.out.contentHash;
                }
                # A secret-ref has no contentHash, so a rotation of that
                # Secret does not roll the pods.
                // lib.optionalAttrs (auth.out ? contentHash) {
                  "checksum/natsAuth" = auth.out.contentHash;
                };
                spec = {
                  automountServiceAccountToken = false;
                  # The servers find each other through the headless
                  # Service, and service links would add variables for
                  # every Service in the namespace.
                  enableServiceLinks = false;
                  # Lame duck mode ends within its 30-second duration: the
                  # 10-second grace period comes out of it. Upstream's
                  # chart adds the two and 20 seconds for shutdown.
                  terminationGracePeriodSeconds = 60;
                  # The image sets no user. nats-server writes only its pid
                  # file and the JetStream store.
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    runAsGroup = 1000;
                    fsGroup = 1000;
                    fsGroupChangePolicy = "OnRootMismatch";
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [ natsContainer ] ++ lib.optional config.metrics.enabled metricsContainer;
                };
              };
              volumeClaimTemplates = lib.optional jetstream {
                metadata.name = "data";
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = toString config.storage.size;
                }
                // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
              };
            };
          }
          |> kix.withMountsOn "nats" [
            configMount
            (kix.mount.emptyDir {
              name = "pid";
              mountPath = builtins.dirOf pidFile;
              medium = "Memory";
              sizeLimit = "1Mi";
            })
          ]
          |> scope.mkStatefulSet;

        # The routes in nats.conf read this Service's `out.fqdn`, so it is
        # applied before the StatefulSet and selects through `rawSelector`;
        # `out.selector` would recurse. It publishes unready addresses so a
        # starting server resolves its peers.
        headlessService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-headless";
          labels."app.kubernetes.io/component" = "headless";
          spec = {
            clusterIP = "None";
            publishNotReadyAddresses = true;
            selector = self.statefulSet.rawSelector;
            ports = headlessPorts;
          };
        };

        clientService =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "client";
            ports = [
              {
                name = "nats";
                port = ports.client;
                targetPort = ports.client;
                protocol = "TCP";
                appProtocol = "tcp";
              }
            ];
          }
          |> scope.mkResource;

        # A Service of its own, so that reading its address opens the
        # monitoring port and not the client port.
        monitoringService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-monitor";
            labels."app.kubernetes.io/component" = "monitor";
            ports = [
              {
                name = "monitor";
                port = ports.monitor;
                targetPort = ports.monitor;
                protocol = "TCP";
                appProtocol = "http";
              }
            ];
          }
          |> scope.mkResource;

        metricsService =
          if scrape then
            self.statefulSet
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              labels."app.kubernetes.io/component" = "metrics";
              ports = [
                {
                  name = "metrics";
                  port = ports.metrics;
                  targetPort = ports.metrics;
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        root = {
          resource = self.clientService;
          out = {
            host = self.clientService.out.fqdn;
            port = toString ports.client;
            url = self.clientService.out.url {
              scheme = "nats";
              port = ports.client;
            };
            monitoringHost = self.monitoringService.out.fqdn;
            monitoringPort = toString ports.monitor;
            credentials = auth;
            inherit jetstream;
            version = kix.image.version config.image;
          };
          # Parts the client Service does not reference itself; `requires`
          # keeps them in the build.
          requires = builtins.filter (r: r != null) [
            self.headlessService
            self.monitoringService
            self.metricsService
          ];
        };
      }
    )

    (kix.healthCheck {
      # The probe logs in with the credentials, so a new password runs it
      # again.
      # kix.healthCheck reruns its probe Job when self.root or a resource in
      # requires changes. In this NATS package, the root is the client Service,
      # which does not change when the servers' image, nats.conf, or resources
      # change. So the StatefulSet is listed in requires, and its pod template's
      # nats.conf ConfigMap checksum annotation ensures config changes also
      # change the StatefulSet and rerun the probe.
      requires =
        { self, ... }:
        [
          self.statefulSet
          self.root.out.credentials
        ];
      env =
        { self, ... }:
        {
          NATS_HOST = self.root.out.host;
          NATS_PORT = self.root.out.port;
          NATS_JETSTREAM = lib.boolToString self.root.out.jetstream;
          NATS_USER = self.root.out.credentials.out.keyRef "username";
          NATS_PASSWORD = self.root.out.credentials.out.keyRef "password";
        };
      script = builtins.readFile ./health-check.py;
    })

    # kix.monitor reads `scope`, `lib`, and `prometheus` from the arguments
    # it is called with, so they are declared here for the build to pass
    # them. It renders the alerts only when the metrics Service exists.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts =
          let
            sel = ''namespace="${scope.namespaceName}", service="${self.metricsService.out.name}"'';
            instance = "NATS ${scope.namespaceName}/${name}";
          in
          {
            NATSMetricsAbsent = {
              expr = "absent(nats_varz_connections{${sel}})";
              "for" = "5m";
              severity = "critical";
              summary = "No server metrics reported for NATS";
              description = "Prometheus has received no server metrics from ${instance} for 5 minutes. The pods may be down or `Pending`, or `nats-server` may not be responding on port 8222. Run `kubectl get pods -n ${scope.namespaceName}` and check the `nats` container logs.";
            };
            NATSServerUnhealthy = {
              expr = "max by (namespace, service, pod) (nats_healthz_status{${sel}}) == 1";
              "for" = "10m";
              severity = "warning";
              summary = "NATS server health check is failing";
              description = "`/healthz` on pod {{ $labels.pod }} (${instance}) has failed for 10 minutes. JetStream may have no metadata leader, or a stream or consumer may be behind. Check the `nats` container logs with `kubectl logs -n ${scope.namespaceName} {{ $labels.pod }} -c nats`.";
            };
            NATSConnectionsNearLimit = {
              expr = "nats_varz_connections{${sel}} / nats_varz_max_connections{${sel}} > 0.9 and nats_varz_max_connections{${sel}} > 0";
              "for" = "10m";
              severity = "warning";
              summary = "NATS server is near its connection limit";
              description = "Pod {{ $labels.pod }} (${instance}) is using {{ $value | humanizePercentage }} of `max_connections`. At 100%, the server rejects new client connections. Close idle client connections or increase `settings.max_connections`.";
            };
            NATSSlowConsumers = {
              expr = "increase(nats_varz_slow_consumers{${sel}}[10m]) > 0";
              "for" = "5m";
              severity = "warning";
              summary = "NATS server is dropping messages for slow consumers";
              description = "Pod {{ $labels.pod }} (${instance}) dropped messages for slow client connections in the last 10 minutes. Inspect connections by pending bytes with `kubectl exec -n ${scope.namespaceName} {{ $labels.pod }} -c nats -- wget -qO- 'http://localhost:8222/connz?sort=pending'`.";
            };
          }
          // lib.optionalAttrs config.jetstream.enabled {
            NATSJetStreamStorageNearLimit = {
              expr = "nats_varz_jetstream_stats_storage{${sel}} / nats_varz_jetstream_config_max_storage{${sel}} > 0.9 and nats_varz_jetstream_config_max_storage{${sel}} > 0";
              "for" = "10m";
              severity = "warning";
              summary = "NATS JetStream file storage is nearly full";
              description = "Pod {{ $labels.pod }} (${instance}) is using {{ $value | humanizePercentage }} of `max_file_store`. At 100%, publishes to file-backed streams fail. Lower stream retention limits, or raise `settings.jetstream.max_file_store` if the `/data` volume has room (`storage.size` cannot be updated in place on an existing StatefulSet).";
            };
          };
      } args
    )
  ];
}
