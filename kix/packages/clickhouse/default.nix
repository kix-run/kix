# ClickHouse, single node (v2_discussions/148).
#
# One of two implementations behind the `clickhouse` alias. This one is a
# StatefulSet Kix renders in full and it stays at one replica for good; a
# replicated install is the operator packages' job. Both expose the `out`
# that ./contract.nix defines and checks, so a consumer written against one
# works against the other.
#
# The part of that promise that takes work is schema. Single-node and
# replicated ClickHouse differ in the DDL they accept (`MergeTree` against
# `ReplicatedMergeTree`, plain DDL against `ON CLUSTER`), so this package
# runs embedded Keeper and defines a one-shard, one-replica cluster with the
# `{cluster}`, `{shard}` and `{replica}` macros. Consumers always write
# replicated DDL (`ON CLUSTER '{cluster}'`, `ReplicatedMergeTree`) and it
# works here exactly as it does on a real cluster.
#
# Embedded Keeper runs inside the server process, so it shares the server's
# memory and CPU limits. A server overloaded by queries or merges slows its
# own Keeper, and when the Keeper session is lost every replicated table
# goes read-only. Nor is there a second copy of the data. For either, use
# clickhouse-cluster with a clickhouse-keeper quorum.
#
# Configuration is ClickHouse's own vocabulary. `serverConfig` and
# `usersConfig` are attrsets of fragments, each rendered as a YAML file into
# config.d/ or users.d/, where ClickHouse merges them over its shipped
# config.xml and users.xml. The package's own fragments are listed at
# `builtinServerConfig` below; a cluster overrides a value by naming the same
# fragment and path, or adds a fragment of its own.
#
# DI deps:
#   storage (required)      a persistent-volume-claim instance, mounted at
#                           /var/lib/clickhouse
#   credentials (required)  a secret or secret-ref instance with a `password`
#                           key, for the `default` user. The password reaches
#                           the server as an env var that users.d reads with
#                           `from_env`, so it never lands in a ConfigMap.
#   prometheus (optional)   ServiceMonitor on the built-in /metrics endpoint
#                           (:9363), and the alerts below. Removing the
#                           `prometheus` fragment drops both.
#
# Alerts (./alerts.nix, shared with clickhouse-cluster):
#   ClickHouseDown                no target up (critical)
#   ClickHouseMetricsMissing      target up, but a metrics section the rules
#                                 read is off (warning)
#   ClickHouseReplicaReadOnly     replicated tables read-only (critical)
#   ClickHouseKeeperSessionLost   no session to embedded Keeper (warning)
#   ClickHouseInsertsRejected     inserts refused with Too many parts
#                                 (critical)
#   ClickHouseTooManyParts        a partition over half of
#                                 merge_tree.parts_to_delay_insert (warning)
#   ClickHouseReplicatedDataLoss  a part no replica holds (critical)
#   ClickHouseMemoryNearLimit     MemoryTracking over 90% of the server cap
#                                 derived from resources.limits.memory
#                                 (warning)
# Left to the kube-prometheus rules: OOM kills and crash loops
# (KubePodCrashLooping), the volume filling (KubePersistentVolumeFillingUp,
# which needs CSI volume stats). Left to dashboards: slow queries,
# connections, merge and mutation backlogs, and detached parts.
#
# Exposes (the contract, shared with clickhouse-cluster):
#   out.httpUrl         "http://<fqdn>:8123"
#   out.nativeEndpoint  "<fqdn>:9000"
#   out.host            the Service FQDN
#   out.ports           { http = "8123"; native = "9000"; }
#   out.username        "default"
#   out.authSecret      the credentials Secret; `out.authSecret.out.keyRef
#                       out.authPasswordKey`
#   out.authPasswordKey "password"
#   out.clusterName     the name `{cluster}` expands to
#   out.version         the server release as YY.M
#   out.replicas        "1"
#   out.replicaHosts    [ "<fqdn>" ], the one replica
#
# root = Service.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;

  ports = {
    http = 8123;
    native = 9000;
    metrics = 9363;
  };

  headlessName = "${name}-headless";

  passwordKey = "password";
  passwordEnv = "CLICKHOUSE_DEFAULT_PASSWORD";
  # Sorts after passwordEnv, which it expands: Kubernetes only substitutes
  # $(VAR) from variables earlier in the list, and mkEnvVars sorts by name.
  keeperIdentityEnv = "CLICKHOUSE_KEEPER_IDENTITY";
  dataPath = "/var/lib/clickhouse";

  contract = import ./contract.nix { inherit lib; };

  # JSON is YAML, and ClickHouse reads *.yaml fragments natively. XML
  # attributes are spelled "@name" in its YAML dialect.
  renderFragments = lib.mapAttrs' (
    fragment: value: lib.nameValuePair "${fragment}.yaml" (builtins.toJSON value)
  );

  # The cluster's fragments over the package's own. A null anywhere in the
  # cluster's side deletes that key, or the whole fragment, which is the
  # only way to take something out of a built-in.
  mergeFragments =
    builtin: overrides:
    lib.filterAttrsRecursive (_: v: v != null) (lib.recursiveUpdate builtin overrides);

  # A null `prometheus` fragment, or a null `prometheus.prometheus` key in
  # it, removes the metrics endpoint, so nothing is left to scrape or alert on.
  metricsEndpointOn =
    serverConfig:
    let
      f = serverConfig.prometheus or { };
    in
    f != null && (f.prometheus or { }) != null;
in
{
  meta = {
    version = "26.3.33";
    description = "ClickHouse, single node with embedded Keeper";
    lifecycle = "stateful";
    defaultAliases = [ "clickhouse" ];
    k8s.minVersion = "1.25";
  };

  deps = {
    credentials.assertions =
      dep:
      lib.optional (!(builtins.elem passwordKey (dep.out.keys or [ ]))) {
        assertion = false;
        message = "clickhouse reads the default user's password from the `${passwordKey}` key of its credentials secret, and the resolved secret declares: ${
          lib.concatStringsSep ", " (dep.out.keys or [ ])
        }. Add `${passwordKey}` to that instance's keys.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-server";
      tag = "26.3.33.24";
      digest = "sha256:810861a2e2d0188744f5f23b2d3ec9ff95812bcb9ddbb8fed13a377a7f305893";
    };

    clusterName = lib.mkOption {
      # It becomes an XML element name under remote_servers.
      type = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*";
      default = "default";
      description = ''
        Name of the one-shard, one-replica cluster this server defines, and
        the value of the `{cluster}` macro. Consumers should write
        `ON CLUSTER '{cluster}'` and never need to know it.
      '';
    };

    serverConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        limits.max_concurrent_queries = 50;
      };
      description = ''
        Server configuration fragments. Each attribute becomes
        config.d/<name>.yaml and is merged over the package's own fragment of
        the same name when there is one (network, logging, prometheus,
        system-logs, keeper, cluster). Set a key, or a whole fragment, to
        null to remove it from the package's own.
      '';
    };

    usersConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Users, profiles and quotas fragments. Each attribute becomes
        users.d/<name>.yaml, merged over the package's own (default-user).
        Null removes, as in serverConfig: to authenticate the default user
        another way, null out `default-user.users.default.password` too, or
        ClickHouse refuses to start with two credentials.
      '';
    };

    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "2Gi";
      };
      description = ''
        ClickHouse sizes itself from the container's limits: its caches and
        server-wide memory cap from the memory limit
        (`max_server_memory_usage_to_ram_ratio`, 0.9 by default) and its
        thread pools from the CPU limit. Without them it sizes from the
        node. The memory limit is required; the CPU limit is a default.
        2Gi is a floor, not a suggestion: at 1Gi background merges fail
        with MEMORY_LIMIT_EXCEEDED under a light insert load.
      '';
    };

    metrics = kix.options.monitor;
    # On by default here, unlike most packages. The probe is what notices a
    # default user left with an empty password (an empty Secret key, or a
    # from_env substitution that did not happen), and that failure looks
    # healthy from every other angle.
    healthCheck = kix.options.healthCheck // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the post-deploy probe. It checks login, that a login with no password is refused, that replicated DDL can work, and that no replicated table is read-only.";
      };
    };
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        storage,
        credentials,
        ...
      }:
      let
        memoryLimit = config.resources.limits.memory or null;

        builtinServerConfig = {
          # Both families with listen_try, as the image's own
          # docker_related_config.xml does: whichever the node has binds. On
          # a dual-stack node "::" takes IPv4 as well and the second bind
          # logs one "Address already in use" warning per port at startup.
          network = {
            listen_host = [
              "::"
              "0.0.0.0"
            ];
            listen_try = 1;
            # The MySQL and PostgreSQL wire emulations are on in the shipped
            # config.xml. Nothing in the contract offers them, so they are
            # not listening. A cluster that wants one sets the port back in
            # serverConfig.network.
            mysql_port."@remove" = "remove";
            postgresql_port."@remove" = "remove";
            # Replica-to-replica fetches. There is one replica.
            interserver_listen_host = "localhost";
          };

          # The root filesystem is read-only and the pod's log is the
          # console, so the two file logs of the shipped config.xml go.
          logging.logger = {
            console = 1;
            # The shipped level is trace, several lines per query. On a
            # console that a log shipper reads, and may well be writing
            # back into this server, that is a feedback loop.
            level = "information";
            log."@remove" = "remove";
            errorlog."@remove" = "remove";
          };

          prometheus.prometheus = {
            endpoint = "/metrics";
            port = ports.metrics;
            metrics = true;
            events = true;
            asynchronous_metrics = true;
            status_info = true;
          };

          # The shipped config.xml enables these tables with no TTL, so they
          # grow until the volume is full. `ttl` merges into each existing
          # section. Only tables that are on upstream belong in this list: a
          # section that upstream ships commented out (zookeeper_log, a row
          # per Keeper request) would be switched on by naming it here.
          # Changing a TTL later makes ClickHouse rename the old table to
          # <name>_0 and leave it, with no TTL; drop it by hand.
          system-logs =
            lib.genAttrs
              [
                "asynchronous_metric_log"
                "background_schedule_pool_log"
                "backup_log"
                "blob_storage_log"
                "error_log"
                "metric_log"
                "part_log"
                "query_log"
                "query_metric_log"
                "query_thread_log"
                "query_views_log"
                "text_log"
                "trace_log"
              ]
              (_: {
                ttl = "event_date + INTERVAL 30 DAY DELETE";
              });

          # Embedded Keeper is not optional: it is what makes
          # `ReplicatedMergeTree` and `ON CLUSTER` DDL work on one node, so
          # schema written here carries over to a replicated cluster
          # unchanged, and the contract's clusterName is always honoured. The
          # server only ever talks to itself here, over localhost, so none of
          # this depends on the pod's name or on DNS.
          cluster = {
            macros = {
              cluster = config.clusterName;
              shard = "01";
              replica = "${name}-0";
            };
            remote_servers = {
              # The shipped config.xml carries example clusters.
              "@replace" = "replace";
              ${config.clusterName}.shard = {
                internal_replication = true;
                replica = {
                  host = "localhost";
                  port = ports.native;
                };
              };
            };
          };

          keeper = {
            keeper_server = {
              tcp_port = 9181;
              server_id = 1;
              log_storage_path = "${dataPath}/coordination/log";
              snapshot_storage_path = "${dataPath}/coordination/snapshots";
              raft_configuration.server = {
                id = 1;
                hostname = "localhost";
                port = 9234;
              };
            };
            zookeeper = {
              node = {
                host = "localhost";
                port = 9181;
              };
              # Keeper has no listen address of its own: its client port
              # follows listen_host, so it is reachable on the pod IP, and
              # it has no login. With an identity the server puts a digest
              # ACL on every znode it creates, so nobody else can write to
              # them. The one that matters is the distributed DDL queue,
              # whose entries the server executes without asking who wrote
              # them. Network policy is still the outer wall; this holds
              # when there is none.
              identity = {
                "@replace" = "replace";
                "@from_env" = keeperIdentityEnv;
              };
            };
          };
        };

        builtinUsersConfig = {
          default-user.users.default = {
            password = {
              "@replace" = "replace";
              "@from_env" = passwordEnv;
              # Not `hide_in_preprocessed`: on 26.3 it makes the server drop
              # the substitution and run with an EMPTY password. See
              # preprocessedMount for how the expanded value stays off disk.
            };
            # SQL-driven users and grants (CREATE USER, GRANT), which is how
            # clickhouse-database gives each consumer its own account.
            access_management = 1;
          };
        };

        # Readiness asks the HTTP handler. Liveness and startup only ask
        # whether the port is open: a server saturated by queries answers
        # /ping late, and restarting it for that turns load into an outage.
        probeTiming = {
          periodSeconds = 10;
          timeoutSeconds = 3;
          failureThreshold = 3;
        };
        readyProbe = probeTiming // {
          httpGet = {
            path = "/ping";
            port = "http";
          };
        };
        aliveProbe = probeTiming // {
          tcpSocket.port = "http";
        };
      in
      if memoryLimit == null then
        throw "clickhouse (${name}): resources.limits.memory is unset. ClickHouse sizes its memory cap from the container limit and falls back to the node's RAM without one. Set config.resources.limits.memory."
      else
        {
          serverConfigMap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-config";
            data = renderFragments (mergeFragments builtinServerConfig config.serverConfig);
          };

          usersConfigMap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-users";
            data = renderFragments (mergeFragments builtinUsersConfig config.usersConfig);
          };

          dataMount = kix.mount.pvc storage { mountPath = dataPath; };
          serverConfigMount = kix.mount.configMap self.serverConfigMap {
            mountPath = "/etc/clickhouse-server/config.d";
            readOnly = true;
          };
          usersConfigMount = kix.mount.configMap self.usersConfigMap {
            mountPath = "/etc/clickhouse-server/users.d";
            readOnly = true;
          };
          tmpMount = kix.mount.emptyDir {
            name = "tmp";
            mountPath = "/tmp";
            sizeLimit = "256Mi";
          };
          # ClickHouse writes the merged config here with substitutions
          # expanded, the default user's password among them. In memory it
          # lives exactly as long as the env var it was read from; on the
          # data volume it would outlive the pod and ride along in every
          # snapshot and backup.
          preprocessedMount = kix.mount.emptyDir {
            name = "preprocessed-configs";
            mountPath = "${dataPath}/preprocessed_configs";
            medium = "Memory";
            sizeLimit = "16Mi";
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
              labels."app.kubernetes.io/name" = "clickhouse";
              spec = {
                # By name: the headless Service is derived from this
                # workload, so the edge runs from it to here.
                serviceName = headlessName;
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.annotations = {
                    "checksum/config" = self.serverConfigMap.out.identityHash;
                    "checksum/users" = self.usersConfigMap.out.identityHash;
                  };
                  spec = {
                    serviceAccountName = self.serviceAccount.out.name;
                    automountServiceAccountToken = false;
                    # A merge in flight finishes or is abandoned cleanly.
                    terminationGracePeriodSeconds = 120;
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 101;
                      runAsGroup = 101;
                      fsGroup = 101;
                      # Not a recursive chown of every part file on every
                      # restart.
                      fsGroupChangePolicy = "OnRootMismatch";
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      {
                        name = "clickhouse";
                        image = kix.image.ref config.image;
                        imagePullPolicy = config.image.pullPolicy;
                        # The server binary directly. The image's entrypoint
                        # exists to chown the data directory and to write
                        # users.d from env vars; fsGroup and usersConfigMap
                        # do both declaratively. It also sets the working
                        # directory and turns the watchdog off, and both of
                        # those are kept below. It would chown any disk or
                        # filesystem cache path declared outside the data
                        # directory too, so a serverConfig that adds one has
                        # to mount it with the same fsGroup.
                        command = [
                          "/usr/bin/clickhouse-server"
                          "--config-file=/etc/clickhouse-server/config.xml"
                        ];
                        workingDir = dataPath;
                        env = kix.mkEnvVars {
                          ${passwordEnv} = credentials.out.keyRef passwordKey;
                          # Otherwise PID 1 is a watchdog that forks the
                          # server, and the kubelet signals the watchdog.
                          CLICKHOUSE_WATCHDOG_ENABLE = "0";
                          ${keeperIdentityEnv} = "clickhouse:$(${passwordEnv})";
                        };
                        ports = [
                          (kix.port "http" ports.http)
                          (kix.port "native" ports.native)
                          (kix.port "metrics" ports.metrics)
                        ];
                        livenessProbe = aliveProbe;
                        readinessProbe = readyProbe;
                        # Replaying a large parts directory after an unclean
                        # stop can take minutes.
                        startupProbe = aliveProbe // {
                          failureThreshold = 60;
                        };
                        inherit (config) resources;
                        securityContext = {
                          runAsNonRoot = true;
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
              self.serverConfigMount
              self.usersConfigMount
              self.tmpMount
              self.preprocessedMount
            ]
            |> scope.mkStatefulSet;

          # Governs the StatefulSet's pod DNS. Nothing dials it. The two
          # Services carry different component labels so a label selector
          # (a ServiceMonitor's, say) can pick one (distinctSameKindLabels).
          headlessService =
            self.statefulSet
            |> kix.service.fromWorkload {
              name = headlessName;
              labels."app.kubernetes.io/component" = "headless";
              ports = [
                {
                  name = "http";
                  port = ports.http;
                  targetPort = "http";
                }
              ];
            }
            |> (
              svc:
              svc
              // {
                spec = svc.spec // {
                  clusterIP = "None";
                };
              }
            )
            |> scope.mkResource;

          service =
            self.statefulSet
            |> kix.service.fromWorkload {
              inherit name;
              labels."app.kubernetes.io/component" = "server";
            }
            |> scope.mkResource;

          root = {
            resource = self.service;
            requires = [
              self.headlessService
            ]
            ++ builtins.filter (p: p != null) [
              (self.serviceMonitor or null)
              (self.prometheusRules or null)
            ];
            out = contract.check "clickhouse (${name})" {
              httpUrl = "http://${self.service.out.fqdn}:${toString ports.http}";
              nativeEndpoint = "${self.service.out.fqdn}:${toString ports.native}";
              host = self.service.out.fqdn;
              ports = {
                http = toString ports.http;
                native = toString ports.native;
              };
              username = "default";
              authSecret = credentials;
              authPasswordKey = passwordKey;
              inherit (config) clusterName;
              version = lib.versions.majorMinor config.image.tag;
              replicas = "1";
              replicaHosts = [ self.service.out.fqdn ];
            };
          };
        }
    )

    # kix.monitor reads `scope`, `lib`, and `prometheus` from the arguments
    # it is called with, so the wrapper names them for the build to pass.
    # Without the metrics endpoint it gets no `prometheus`, which drops the
    # ServiceMonitor and the rules. The package's own fragments set none of
    # the keys alerts.nix reads, so it is given the instance's serverConfig
    # alone.
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
        service = "service";
        port = "metrics";
        alerts = import ./alerts.nix { inherit lib kix; } {
          sel = ''namespace="${scope.namespaceName}",service="${self.service.out.name}"'';
          by = "namespace, service";
          instance = "${scope.namespaceName}/${name}";
          memoryLimit = config.resources.limits.memory or null;
          fragments = config.serverConfig;
        };
      } (args // lib.optionalAttrs (!metricsEndpointOn config.serverConfig) { prometheus = null; })
    )

    (kix.healthCheck {
      env =
        { self, config, ... }:
        {
          CLICKHOUSE_URL = self.root.out.httpUrl;
          CLICKHOUSE_USER = self.root.out.username;
          CLICKHOUSE_PASSWORD = self.root.out.authSecret.out.keyRef self.root.out.authPasswordKey;
          CLICKHOUSE_CLUSTER = self.root.out.clusterName;
          CLICKHOUSE_REPLICA_URLS = self.root.out.httpUrl;
        };
      script = builtins.readFile ./health-check.py;
    })
  ];
}
