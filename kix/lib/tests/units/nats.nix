# Tests for the nats package: the topology `clustered` and `replicas`
# choose, the availability levels each mode is refused at, the rendered
# nats.conf, the `out` a consumer reads and the network policy each address opens, auth through the natsAuth
# dependency, the refusals of `settings`, `env`, and `replicas`, each
# beside a positive control, two same-named instances in two namespaces,
# and the alert rules and what each is gated on.

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  alertRulesOf,
  allSelect,
  prometheusStub,
  netpolOn,
  multiZone,
  ...
}:

let
  natsPackage = import ../../../packages/experimental/nats;
  secretPackage = import ../../../packages/stable/secret;
  settingsCheck = import ../../../packages/experimental/nats/settings.nix { inherit lib; };

  ports = {
    client = 4222;
    cluster = 6222;
    monitor = 8222;
  };

  # A consumer that writes the addresses it reads from its `nats`
  # dependency into its environment. `fields` picks which.
  consumerPackage = fields: {
    meta = {
      description = "NATS consumer stand-in";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        kix,
        nats,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = scope.instanceName;
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "consumer";
                image = "example.com/consumer:1";
                env = kix.mkEnvVars (fields nats);
              }
            ];
          };
        };
        root = self.deployment;
      };
  };
  clientFields = nats: {
    NATS_URL = nats.out.url;
    NATS_HOST = nats.out.host;
    NATS_PORT = nats.out.port;
  };
  pollerFields = nats: {
    MONITOR = "${nats.out.monitoringHost}:${nats.out.monitoringPort}";
  };

  # `nats` in `messaging` with `config`, plus `modules`. With `auth`, a
  # secret aliased natsAuth beside it; with `consumer`, a consumer reading
  # `fields` in `consumerNamespace`, which names the instance with `ref`.
  natsCluster =
    {
      config ? { },
      auth ? true,
      consumer ? null,
      consumerNamespace ? "messaging",
      level ? "none",
      modules ? [ ],
    }:
    mkCluster (
      [
        (levels.${level})
        (
          { ref, ... }:
          {
            instances.${consumerNamespace} = lib.optionalAttrs (consumer != null) {
              consumer = {
                package = consumerPackage consumer;
                deps.nats = ref.messaging.nats;
              };
            };
          }
        )
        {
          instances.messaging = {
            nats = {
              package = natsPackage;
              inherit config;
            };
          }
          // lib.optionalAttrs auth {
            nats-auth = {
              package = secretPackage;
              aliases = [ "natsAuth" ];
              config.stringData = {
                username = "app";
                password = "pw";
              };
            };
          };
        }
      ]
      ++ modules
    );
  zone = lib.recursiveUpdate multiZone { cluster.availability.default = "zone"; };
  none.cluster.availability.default = "none";
  levels = {
    inherit none zone;
    pod = {
      cluster.capabilities.multiNode = true;
      cluster.availability.default = "pod";
    };
  };
  clustered.clustered = true;

  # The messages of the package's failed assertions for `config` at
  # `availability`. The assertions read only `clustered` and `replicas`.
  failedMessages =
    availability: config:
    let
      attrs = natsPackage {
        scope = {
          instanceName = "nats";
          namespaceName = "messaging";
        };
        inherit lib availability;
        kix = kixlib;
      };
    in
    map (a: a.message) (builtins.filter (a: !a.assertion) (attrs.assertions { inherit config; }));
  withPrometheus.instances.monitoring.prometheus.package = prometheusStub;

  ms = cluster: manifests cluster;
  inNs = ns: builtins.filter (m: (m.metadata.namespace or null) == ns);
  stsOf = all: byName "nats" (ofKind "StatefulSet" (inNs "messaging" all));
  confOf =
    all:
    builtins.fromJSON (
      builtins.replaceStrings
        [ "$POD_NAME" "$NATS_USER" "$NATS_PASSWORD" ]
        [
          ''"<POD_NAME>"''
          ''"<NATS_USER>"''
          ''"<NATS_PASSWORD>"''
        ]
        (byName "nats-config" (ofKind "ConfigMap" (inNs "messaging" all))).data."nats.conf"
    );
  containerOf = name: sts: lib.findFirst (c: c.name == name) null sts.spec.template.spec.containers;
  envOf = c: lib.listToAttrs (map (e: lib.nameValuePair e.name e) c.env);

  # The ports the stub enforcer's policies in `messaging` admit from
  # `instance`'s pods.
  ingressPortsFrom =
    instance: all:
    let
      cnps = builtins.filter (m: lib.hasPrefix "${instance}-deployment-${instance}-to-" m.metadata.name) (
        ofKind "CiliumNetworkPolicy" (inNs "messaging" all)
      );
    in
    lib.sort lib.lessThan (
      lib.concatMap (p: lib.concatMap (i: map (x: x.port) (i.ports or [ ])) p.spec.ingress) cnps
    );
in
{
  # By default, at availability none: one server, no cluster block,
  # JetStream on a 10Gi claim, max_file_store at the claim size, memory
  # streams off, and a headless Service with the client port only. With
  # `clustered` at zone: three servers, routes to each pod over the
  # headless Service, and the route port.
  nats-topology =
    let
      oneAll = ms (natsCluster { });
      one = stsOf oneAll;
      oneConf = confOf oneAll;
      threeAll = ms (natsCluster {
        level = "zone";
        config = clustered;
      });
      three = stsOf threeAll;
      threeConf = confOf threeAll;
      headlessPorts =
        all: map (p: p.port) (byName "nats-headless" (ofKind "Service" (inNs "messaging" all))).spec.ports;
      fqdn = "nats-headless.messaging.svc.cluster.local";
    in
    (
      one.spec.replicas == 1
      && !(oneConf ? cluster)
      && oneConf.server_name == "<POD_NAME>"
      && oneConf.port == ports.client
      && oneConf.http_port == ports.monitor
      &&
        oneConf.jetstream == {
          store_dir = "/data";
          max_file_store = 10737418240;
          max_memory_store = 0;
        }
      && (builtins.head one.spec.volumeClaimTemplates).spec.resources.requests.storage == "10Gi"
      && headlessPorts oneAll == [ ports.client ]
      && one.spec.podManagementPolicy == "Parallel"
      && lib.hasPrefix "docker.io/library/nats:2.15.3-alpine@sha256:" (containerOf "nats" one).image
      && three.spec.replicas == 3
      &&
        threeConf.cluster == {
          name = "nats";
          port = ports.cluster;
          no_advertise = true;
          routes = map (i: "nats://nats-${toString i}.${fqdn}:${toString ports.cluster}") [
            0
            1
            2
          ];
        }
      &&
        headlessPorts threeAll == [
          ports.client
          ports.cluster
        ]
    )
    || throw "nats topology: ${
      builtins.toJSON {
        inherit oneConf threeConf;
        oneReplicas = one.spec.replicas;
        threeReplicas = three.spec.replicas;
      }
    }";

  # A consumer reads the client address from `out.url`, `out.host`, and
  # `out.port`, and a poller the monitoring address. Each gets a policy
  # for its own port only, in the instance's namespace and in another
  # one that names the instance with `ref`.
  nats-out-and-policy =
    let
      client = natsCluster {
        consumer = clientFields;
        modules = [ netpolOn ];
      };
      poller = natsCluster {
        consumer = pollerFields;
        modules = [ netpolOn ];
      };
      remoteClient = natsCluster {
        consumer = clientFields;
        consumerNamespace = "apps";
        modules = [ netpolOn ];
      };
      remotePoller = natsCluster {
        consumer = pollerFields;
        consumerNamespace = "apps";
        modules = [ netpolOn ];
      };
      env =
        all:
        envOf (builtins.head (byName "consumer" (ofKind "Deployment" all)).spec.template.spec.containers);
      clientEnv = env (ms client);
      pollerEnv = env (ms poller);
      out = client.instances.messaging.nats.out;
    in
    (
      clientEnv.NATS_URL.value == "nats://nats.messaging.svc.cluster.local:4222"
      && clientEnv.NATS_HOST.value == "nats.messaging.svc.cluster.local"
      && clientEnv.NATS_PORT.value == "4222"
      && pollerEnv.MONITOR.value == "nats-monitor.messaging.svc.cluster.local:8222"
      && ingressPortsFrom "consumer" (ms client) == [ 4222 ]
      && ingressPortsFrom "consumer" (ms poller) == [ 8222 ]
      && ingressPortsFrom "consumer" (ms remoteClient) == [ 4222 ]
      && ingressPortsFrom "consumer" (ms remotePoller) == [ 8222 ]
      && out.credentials != null
      && out.jetstream
      && out.version == "2.15.3"
    )
    || throw "nats out: ${
      builtins.toJSON {
        inherit clientEnv pollerEnv;
        clientPorts = ingressPortsFrom "consumer" (ms client);
        pollerPorts = ingressPortsFrom "consumer" (ms poller);
      }
    }";

  # nats.conf names the login as variables, the container sets them from
  # the natsAuth Secret in single quotes after the raw values, and
  # `out.credentials` is the secret. Without the dependency the build
  # fails. A consumer in another namespace that reads `out.credentials`
  # fails too, because a Secret reference resolves only in the pod's own
  # namespace; reading only the address evaluates.
  nats-auth =
    let
      all = ms (natsCluster { });
      conf = confOf all;
      nats = containerOf "nats" (stsOf all);
      names = map (e: e.name) nats.env;
      env = envOf nats;
      healthEnv = envOf (
        builtins.head (byName "nats-health" (ofKind "Job" all)).spec.template.spec.containers
      );
      position = n: lib.lists.findFirstIndex (x: x == n) null names;
    in
    (
      conf.authorization == {
        user = "<NATS_USER>";
        password = "<NATS_PASSWORD>";
      }
      &&
        env.AUTH_PASSWORD.valueFrom.secretKeyRef == {
          name = "nats-auth";
          key = "password";
        }
      && env.NATS_PASSWORD.value == "'$(AUTH_PASSWORD)'"
      && env.NATS_USER.value == "'$(AUTH_USER)'"
      && position "AUTH_PASSWORD" < position "NATS_PASSWORD"
      && position "AUTH_USER" < position "NATS_USER"
      && healthEnv.NATS_PASSWORD.valueFrom.secretKeyRef.name == "nats-auth"
      && evalFails (natsCluster {
        auth = false;
      })
      && !evalFails (natsCluster { })
      && evalFails (natsCluster {
        consumerNamespace = "apps";
        consumer = nats: { NATS_PASSWORD = nats.out.credentials.out.keyRef "password"; };
      })
      && !evalFails (natsCluster {
        consumerNamespace = "apps";
        consumer = clientFields;
      })
    )
    || throw "nats auth: ${builtins.toJSON { inherit conf names; }}";

  # Each refused settings key gets one problem naming it; keys the package
  # leaves to the user pass. The build refuses them too.
  nats-settings-refusals =
    let
      check =
        {
          clustered ? true,
          jetstream ? true,
        }:
        settingsCheck.problems { inherit ports clustered jetstream; };
      only = option: problems: builtins.length problems == 1 && (builtins.head problems).option == option;
      got = {
        port = check { } { port = 1; };
        upper = check { } { Port = 1; };
        monitor = check { } { monitor_port = 1; };
        auth = check { } { authorization.user = "x"; };
        leaf = check { } { leafnodes.port = 7422; };
        routes = check { } { cluster.routes = [ ]; };
        clusterUpper = check { } { cluster.Name = "x"; };
        clusterOff = check { clustered = false; } { cluster.pool_size = 3; };
        storeDir = check { } { jetstream.store_dir = "/tmp"; };
        key = check { } { jetstream.key = "secret"; };
        jsOff = check { jetstream = false; } { jetstream.max_memory_store = 1; };
        jsBool = check { } { jetstream = "enabled"; };
        # Spellings server/opts.go accepts for keys the package writes or
        # leaves to the user.
        store = check { } { jetstream.store = "/tmp"; };
        maxFile = check { } { jetstream.max_file = 1; };
        maxMem = check { } { jetstream.max_mem = 1; };
        maxMemStore = check { } { jetstream.max_mem_store = 1; };
        tpm = check { } { jetstream.tpm.keys_file = "/k"; };
        logFile = check { } { log_file = "/tmp/nats.log"; };
        logfile = check { } { logfile = "/tmp/nats.log"; };
        portsFile = check { } { ports_file_dir = "/tmp"; };
        prof = check { } { prof_port = 65432; };
        sentinel = check { } { default_sentinel = "x"; };
        resolverTls = check { } { resolver_tls = { }; };
        pinned = check { } { resolver_pinned_accounts = [ ]; };
        maxConn = check { } { max_conn = 10; };
        advertise = check { } { cluster.advertise = "x:6222"; };
        fine = check { } {
          max_payload = 1048576;
          max_connections = 10;
          cluster.pool_size = 3;
          cluster.cluster_advertise = "x:6222";
          jetstream.max_memory_store = 1073741824;
          jetstream.max_file_store = 1073741824;
          jetstream.sync_interval = "2m";
          debug = true;
        };
      };
      merged = confOf (
        ms (natsCluster {
          config.settings = {
            max_payload = 1048576;
            jetstream.max_file_store = 1073741824;
          };
        })
      );
    in
    (
      only "settings.port" got.port
      && only "settings.Port" got.upper
      && only "settings.monitor_port" got.monitor
      && only "settings.authorization" got.auth
      && only "settings.leafnodes" got.leaf
      && only "settings.cluster.routes" got.routes
      && only "settings.cluster.Name" got.clusterUpper
      && only "settings.cluster" got.clusterOff
      && only "settings.jetstream.store_dir" got.storeDir
      && only "settings.jetstream.key" got.key
      && only "settings.jetstream" got.jsOff
      && only "settings.jetstream" got.jsBool
      && only "settings.jetstream.store" got.store
      && only "settings.jetstream.max_file" got.maxFile
      && only "settings.jetstream.max_mem" got.maxMem
      && only "settings.jetstream.max_mem_store" got.maxMemStore
      && only "settings.jetstream.tpm" got.tpm
      && only "settings.log_file" got.logFile
      && only "settings.logfile" got.logfile
      && only "settings.ports_file_dir" got.portsFile
      && only "settings.prof_port" got.prof
      && only "settings.default_sentinel" got.sentinel
      && only "settings.resolver_tls" got.resolverTls
      && only "settings.resolver_pinned_accounts" got.pinned
      && only "settings.max_conn" got.maxConn
      && only "settings.cluster.advertise" got.advertise
      && got.fine == [ ]
      && merged.max_payload == 1048576
      && merged.jetstream.max_file_store == 1073741824
      && merged.jetstream.store_dir == "/data"
      && evalFails (natsCluster {
        config.settings.port = 1;
      })
      && evalFails (natsCluster {
        config.settings.cluster.pool_size = 3;
      })
      && !evalFails (natsCluster {
        level = "zone";
        config = clustered // {
          settings.cluster.pool_size = 3;
        };
      })
    )
    || throw "nats settings refusals: ${builtins.toJSON got}";

  # The mode never follows the availability level, and a level that
  # disagrees with it is refused: standalone at pod and above, clustered at
  # none. Each refusal names the instance's own availability setting and
  # the backup and restore steps, and sits beside a passing case. The
  # replica count must be 1 standalone, and odd and at least 3 clustered.
  nats-mode-refusals =
    let
      says =
        fragment: messages: builtins.length messages == 1 && lib.hasInfix fragment (builtins.head messages);
      got = {
        standaloneAtPod = failedMessages "pod" {
          clustered = false;
          replicas = 1;
        };
        standaloneAtZone = failedMessages "zone" {
          clustered = false;
          replicas = 1;
        };
        clusteredAtNone = failedMessages "none" {
          clustered = true;
          replicas = 3;
        };
        standaloneThree = failedMessages "none" {
          clustered = false;
          replicas = 3;
        };
        clusterEven = failedMessages "zone" {
          clustered = true;
          replicas = 4;
        };
        clusterOne = failedMessages "zone" {
          clustered = true;
          replicas = 1;
        };
        standaloneAtNone = failedMessages "none" {
          clustered = false;
          replicas = 1;
        };
        clusterFive = failedMessages "pod" {
          clustered = true;
          replicas = 5;
        };
      };
      fixes =
        availability: config:
        map (a: a.fix) (
          builtins.filter (a: !a.assertion) (
            (natsPackage {
              scope = {
                instanceName = "nats";
                namespaceName = "messaging";
              };
              inherit lib availability;
              kix = kixlib;
            }).assertions
              { inherit config; }
          )
        );
      standaloneFix = builtins.head (
        fixes "zone" {
          clustered = false;
          replicas = 1;
        }
      );
      clusteredFix = builtins.head (
        fixes "none" {
          clustered = true;
          replicas = 3;
        }
      );
    in
    (
      says "orphaned" got.standaloneAtPod
      && says "`zone`" got.standaloneAtZone
      && says "`none`" got.clusteredAtNone
      && says "3" got.standaloneThree
      && says "4" got.clusterEven
      && says "1" got.clusterOne
      && got.standaloneAtNone == [ ]
      && got.clusterFive == [ ]
      && lib.hasInfix ''instances.messaging.nats.availability = \"none\";'' (
        builtins.toJSON standaloneFix
      )
      && lib.hasInfix "nats stream backup" standaloneFix
      && lib.hasInfix "nats stream restore" standaloneFix
      && lib.hasInfix ''instances.messaging.nats.availability = \"pod\";'' (builtins.toJSON clusteredFix)
      # The defaults at none build one standalone server; at zone the build
      # fails until `clustered` is set, and then builds three.
      && !evalFails (natsCluster { })
      && evalFails (natsCluster {
        level = "zone";
      })
      && evalFails (natsCluster {
        level = "pod";
      })
      && !evalFails (natsCluster {
        level = "pod";
        config = clustered;
      })
      && evalFails (natsCluster {
        config = clustered;
      })
      && evalFails (natsCluster {
        level = "zone";
        config = clustered // {
          replicas = 2;
        };
      })
      && !evalFails (natsCluster {
        level = "zone";
        config = clustered // {
          replicas = 5;
        };
      })
    )
    || throw "nats mode refusals: ${builtins.toJSON { inherit got standaloneFix clusteredFix; }}";

  # env refuses the variables the package sets, and GOMEMLIMIT defaults to
  # 80% of the memory limit and may be set.
  nats-env =
    let
      gomemlimit =
        config:
        (envOf (
          containerOf "nats" (
            stsOf (
              ms (natsCluster {
                inherit config;
              })
            )
          )
        )).GOMEMLIMIT.value;
    in
    (
      gomemlimit { } == toString (1073741824 * 8 / 10)
      && gomemlimit { env.GOMEMLIMIT = "512MiB"; } == "512MiB"
      && evalFails (natsCluster {
        config.env.POD_NAME = "x";
      })
      && evalFails (natsCluster {
        config.env.NATS_PASSWORD = "x";
      })
      && evalFails (natsCluster {
        config.env.AUTH_PASSWORD = "x";
      })
      && !evalFails (natsCluster {
        config.env.TZ = "UTC";
      })
    )
    || throw "nats env: GOMEMLIMIT ${gomemlimit { }}, or a refusal or control failed";

  # With JetStream off: no claims, no jetstream block, no -jsz flag, and
  # no storage alert.
  nats-jetstream-off =
    let
      all = ms (natsCluster {
        config.jetstream.enabled = false;
        modules = [ withPrometheus ];
      });
      sts = stsOf all;
      rules = alertRulesOf "PrometheusRule" "nats" all;
    in
    (
      sts.spec.volumeClaimTemplates == [ ]
      && !((confOf all) ? jetstream)
      && !(builtins.elem "-jsz=all" (containerOf "metrics" sts).args)
      && !(rules ? NATSJetStreamStorageNearLimit)
      && rules ? NATSMetricsAbsent
      && !(lib.any (m: m.name == "data") ((containerOf "nats" sts).volumeMounts or [ ]))
    )
    || throw "nats with JetStream off: ${builtins.toJSON sts.spec}";

  # The alerts render with a prometheus dependency and select the
  # instance's metrics Service. The exporter sidecar follows
  # metrics.enabled alone; the Service and rules also need the dependency.
  nats-alerts =
    let
      all = ms (natsCluster {
        modules = [ withPrometheus ];
      });
      rules = alertRulesOf "PrometheusRule" "nats" all;
      bare = ms (natsCluster { });
      off = ms (natsCluster {
        config.metrics.enabled = false;
        modules = [ withPrometheus ];
      });
      services = all: map (m: m.metadata.name) (ofKind "Service" (inNs "messaging" all));
    in
    (
      lib.attrNames rules == [
        "NATSConnectionsNearLimit"
        "NATSJetStreamStorageNearLimit"
        "NATSMetricsAbsent"
        "NATSServerUnhealthy"
        "NATSSlowConsumers"
      ]
      && allSelect ''namespace="messaging", service="nats-metrics"'' rules
      && lib.all (
        r:
        builtins.elem r.labels.severity [
          "critical"
          "warning"
        ]
      ) (lib.attrValues rules)
      && alertRulesOf "PrometheusRule" "nats" bare == null
      && alertRulesOf "PrometheusRule" "nats" off == null
      && containerOf "metrics" (stsOf bare) != null
      && containerOf "metrics" (stsOf off) == null
      && !(builtins.elem "nats-metrics" (services bare))
      && builtins.elem "nats-metrics" (services all)
    )
    || throw "nats alerts: ${builtins.toJSON (lib.attrNames rules)}";

  # The probe Job reruns when the servers change. A `settings` change leaves
  # the client Service (the root) unchanged, but it changes the Job's pod
  # template annotations through the StatefulSet. A change to the probe's
  # own inputs is not needed for this.
  nats-health-check-follows-servers =
    let
      annotationsOf = all: (byName "nats-health" (ofKind "Job" all)).spec.template.metadata.annotations;
      base = annotationsOf (ms (natsCluster { }));
      changed = annotationsOf (
        ms (natsCluster {
          config.settings.max_payload = 2097152;
        })
      );
    in
    (base ? "checksum/statefulset-nats" && base != changed)
    || throw "nats health check annotations: ${builtins.toJSON { inherit base changed; }}";

  # The exporter opens its port only after it reads /varz, retrying every
  # 30 seconds by default, so its startup probe must allow longer than
  # that before liveness can restart it.
  nats-exporter-startup-budget =
    let
      probe = (containerOf "metrics" (stsOf (ms (natsCluster { })))).startupProbe;
    in
    (probe.tcpSocket.port == 7777 && probe.periodSeconds * probe.failureThreshold > 30)
    || throw "nats exporter startup probe: ${builtins.toJSON probe}";

  # Two instances named nats in two namespaces evaluate side by side.
  nats-two-namespaces =
    let
      cluster = mkCluster [
        {
          instances = lib.genAttrs [ "prod" "dev" ] (_: {
            nats.package = natsPackage;
            nats-auth = {
              package = secretPackage;
              aliases = [ "natsAuth" ];
              config.stringData = {
                username = "app";
                password = "pw";
              };
            };
            nats.config = clustered;
          });
        }
        zone
      ];
      sets = map (m: m.metadata.namespace) (ofKind "StatefulSet" (ms cluster));
    in
    lib.sort lib.lessThan sets == [
      "dev"
      "prod"
    ]
    || throw "nats in two namespaces: ${builtins.toJSON sets}";

}
