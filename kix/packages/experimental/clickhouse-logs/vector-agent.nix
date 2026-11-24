# The Vector agent that clickhouse-logs and loki-logs both run: image,
# release, options, the parts of Vector's config that every backend shares,
# the pod spec, RBAC, the guarded config merge, and the health check. A change
# here applies to both packages.
#
# The file lives in clickhouse-logs because every directory under
# kix/packages is a package. loki-logs imports it as
#   vectorAgent = import ../clickhouse-logs/vector-agent.nix { inherit lib kix; };
#
# Each package keeps its own parts and deps: it builds the ConfigMap from
# `mergeConfig`, the DaemonSet from `podSpec` plus its own mounts, and the
# metrics Service that `healthCheck` reads through `self.root.out.metricsUrl`.
#
# Upgrades: Vector keeps one file of state, the read position in each log
# file (`kubernetes_logs/checkpoints.json` under the hostPath data
# directory), and upstream says nothing about upgrading or going back
# between releases. In a test, 0.62.0 took over the read positions 0.58.0
# had written and shipped every line once, with none lost or repeated, and
# 0.58.0 did the same with the positions 0.62.0 wrote. To go back, deploy
# the previous package version.

{ lib, kix }:
let
  version = "0.62.0";
  metricsPort = 9598;
  # Vector's 0.59 upgrade guide drops Kubernetes 1.31 and asks for 1.32 or
  # later, and names no upper bound. Move it with `version`.
  k8s = {
    minVersion = "1.32";
    reason = "[K3359] Vector ${version} supports Kubernetes 1.32 and later. Move the cluster to Kubernetes 1.32 or later first, or deploy a Kix release with an older version of this package";
  };
  # Each package mounts its ConfigMap at `configDir`, with the merged
  # settings under the key `configFile`.
  configDir = "/etc/vector";
  configFile = "vector.yaml";
  configPath = "${configDir}/${configFile}";
  dataDir = "/var/lib/vector";

  # Vector's config sources (`vector --help`). The package's merged
  # `settings` is the only one, so locked paths cannot be overridden from a
  # second file.
  configFlags = [
    "--config"
    "-c"
    "--config-dir"
    "-C"
    "--config-yaml"
    "--config-json"
    "--config-toml"
  ];
  configEnvVars = [
    "VECTOR_CONFIG"
    "VECTOR_CONFIG_DIR"
    "VECTOR_CONFIG_YAML"
    "VECTOR_CONFIG_JSON"
    "VECTOR_CONFIG_TOML"
  ];
in
{
  inherit
    version
    metricsPort
    k8s
    configDir
    configFile
    ;

  options = {
    image = kix.options.image {
      repository = "docker.io/timberio/vector";
      tag = "${version}-distroless-libc";
      digest = "sha256:22100806cedabab3768edd6ac919be1a3a026b1020c5b280174a54573572db9d";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "96Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    };

    env = kix.options.env // {
      description = ''
        Extra environment variables for the vector container, such as
        `VECTOR_LOG = "debug"`. A value is a string, a `fieldRef` source, or a
        `kix.untrackedRef` secretKeyRef. The package sets
        `VECTOR_SELF_NODE_NAME` and refuses `VECTOR_CONFIG`,
        `VECTOR_CONFIG_DIR`, `VECTOR_CONFIG_YAML`, `VECTOR_CONFIG_JSON`, and
        `VECTOR_CONFIG_TOML`: put configuration in `settings`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--threads"
        "2"
      ];
      description = ''
        Flags appended after `--config ${configPath}`. Vector's config-source
        flags (${lib.concatMapStringsSep ", " (f: "`${f}`") configFlags}) fail
        evaluation: put configuration in `settings`.
      '';
    };
  };

  # The config every backend shares: read positions under the hostPath
  # `podSpec` mounts, every pod's log files, and Vector's own metrics on
  # `metricsPort` for the probes, the metrics Service, and the health check.
  baseConfig = {
    data_dir = dataDir;
    sources = {
      kubernetes_logs.type = "kubernetes_logs";
      internal_metrics.type = "internal_metrics";
    };
    sinks.metrics = {
      type = "prometheus_exporter";
      inputs = [ "internal_metrics" ];
      address = "0.0.0.0:${toString metricsPort}";
    };
  };

  # `base` (the package's config, built on `baseConfig`) with the instance's
  # `settings` merged over it. `sink` is the component id of the package's
  # backend sink. Its `type` and `endpoint` are locked: the endpoint carries
  # the backend's address, and with it the dependency edge and the derived
  # egress. The `metrics` sink's `type`, `inputs`, and `address` and the
  # `internal_metrics` source's `type` are locked because the probes, the
  # metrics Service, and the health check read them; their other keys stay
  # open. `locked` adds the package's own paths. A null in `settings`
  # removes an unlocked key.
  mergeConfig =
    {
      scope,
      sink,
      locked ? [ ],
    }:
    base: user:
    lib.filterAttrsRecursive (_: v: v != null) (
      kix.mergeGuarded {
        inherit scope;
        option = "settings";
        locked = [
          [ "data_dir" ]
          [
            "sources"
            "internal_metrics"
            "type"
          ]
          [
            "sinks"
            "metrics"
            "type"
          ]
          [
            "sinks"
            "metrics"
            "inputs"
          ]
          [
            "sinks"
            "metrics"
            "address"
          ]
          [
            "sinks"
            sink
            "type"
          ]
          [
            "sinks"
            sink
            "endpoint"
          ]
        ]
        ++ locked;
      } base user
    );

  # The DaemonSet's pod spec. The caller adds its config mount (and any
  # other) with `kix.withMounts` on the DaemonSet body. `self.serviceAccount`
  # must be the package's ServiceAccount part.
  podSpec =
    {
      scope,
      name,
      config,
      self,
    }:
    {
      serviceAccount = self.serviceAccount;
      # Every node's logs, the control plane's included.
      tolerations = [
        {
          operator = "Exists";
          effect = "NoSchedule";
        }
      ];
      securityContext.seccompProfile.type = "RuntimeDefault";
      # Long enough to flush the batch in hand.
      terminationGracePeriodSeconds = 30;
      containers = [
        {
          name = "vector";
          image = kix.image.ref config.image;
          imagePullPolicy = config.image.pullPolicy;
          # Vector parses flags with clap (src/cli.rs upstream).
          args = kix.mergeArgs {
            inherit scope;
            parser = "gnu";
            args = [
              {
                flags = [
                  [
                    "--config"
                    configPath
                  ]
                ];
                names = configFlags;
                reason = "Vector reads its configuration from the file built from settings.";
                fix = "Remove it from extraArgs and configure Vector in settings instead.";
              }
            ];
          } config.extraArgs;
          env = kix.mkEnvVars (
            kix.mergeEnv {
              inherit scope;
              owned = [
                {
                  vars.VECTOR_SELF_NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                  from = "the pod's node, which the kubernetes_logs source reads";
                  fix = "Remove it.";
                }
                {
                  names = configEnvVars;
                  from = "the package's settings, Vector's only config source";
                  fix = "Put configuration in settings.";
                }
              ];
            } config.env
          );
          ports = [ (kix.port "metrics" metricsPort) ];
          # The exporter is served by the same topology as the pipeline,
          # so it answers only once the config loaded.
          readinessProbe = {
            httpGet = {
              path = "/metrics";
              port = "metrics";
            };
            periodSeconds = 10;
          };
          livenessProbe = {
            tcpSocket.port = "metrics";
            periodSeconds = 20;
            failureThreshold = 6;
          };
          inherit (config) resources;
          # The kubelet writes pod logs as root, mode 0640, so reading them
          # takes uid 0. Nothing else is granted: no capabilities, a
          # read-only root, and the log directory itself mounted read-only.
          securityContext = {
            runAsUser = 0;
            allowPrivilegeEscalation = false;
            readOnlyRootFilesystem = true;
            capabilities.drop = [ "ALL" ];
          };
          volumeMounts = [
            {
              name = "var-log";
              mountPath = "/var/log";
              readOnly = true;
            }
            {
              name = "data";
              mountPath = dataDir;
            }
          ];
        }
      ];
      volumes = [
        {
          name = "var-log";
          hostPath.path = "/var/log";
        }
        # Read positions. On the node so a restarted agent resumes where it
        # stopped and neither drops nor re-sends what it had already read.
        # Named `<namespace>.<instance>` like the ClusterRole below, so it is
        # unique to the instance.
        {
          name = "data";
          hostPath = {
            path = "${dataDir}/${scope.namespaceName}.${name}";
            type = "DirectoryOrCreate";
          };
        }
      ];
    };

  # What the kubernetes_logs source watches to put a namespace, labels, and
  # a node on each line. The role name joins the namespace and the instance
  # with a dot. Neither can contain one (the instance name also names the
  # metrics Service, an RFC 1035 label), so two instances never share a
  # ClusterRole.
  rbac =
    {
      scope,
      self,
      name,
    }:
    let
      inherit (scope.rbac)
        core
        grant
        watch
        mkClusterRoleSet
        ;
    in
    mkClusterRoleSet scope {
      subjects = [
        {
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = scope.namespaceName;
        }
      ];
      labels = scope.selectorLabels;
      roles.${"${scope.namespaceName}.${name}"} = grant [
        (core.pods |> watch)
        (core.namespaces |> watch)
        (core.nodes |> watch)
      ];
    };

  # Post-deploy probe over the agents behind `self.root.out.metricsUrl`
  # (health-check.py). `sink` is the component id it watches.
  healthCheck =
    { sink }:
    kix.healthCheck {
      env =
        { self, ... }:
        {
          VECTOR_METRICS_URL = self.root.out.metricsUrl;
          VECTOR_SINK = sink;
        };
      script = builtins.readFile ./health-check.py;
    };
}
