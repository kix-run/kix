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

{ lib, kix }:
let
  version = "0.58.0";
  metricsPort = 9598;
  configPath = "/etc/vector/vector.yaml";
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
  inherit version metricsPort;

  options = {
    image = kix.options.image {
      repository = "docker.io/timberio/vector";
      tag = "${version}-distroless-libc";
      digest = "sha256:6c93dfe2554cc7e38316d618961cd657d5271c7a7aa727e0007502b28cb82c2e";
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
      kubernetes_logs = {
        type = "kubernetes_logs";
        # The source's default template: it reads the node name from
        # VECTOR_SELF_NODE_NAME, which `podSpec` sets.
        self_node_name = "\${VECTOR_SELF_NODE_NAME}";
      };
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
  # egress. `locked` adds the package's own paths. A null in `settings`
  # removes an unlocked key.
  mergeConfig =
    {
      who,
      sink,
      locked ? [ ],
    }:
    base: user:
    lib.filterAttrsRecursive (_: v: v != null) (
      kix.mergeGuarded {
        inherit who;
        what = "settings";
        locked = [
          [ "data_dir" ]
          [
            "sources"
            "internal_metrics"
          ]
          [
            "sinks"
            "metrics"
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
      who,
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
          args = [
            "--config"
            configPath
          ]
          ++ kix.guardArgs {
            inherit who;
            owned = lib.genAttrs configFlags (
              _: "the package's merged settings are Vector's only config source; put configuration in settings."
            );
          } config.extraArgs;
          env = kix.mkEnvVars (
            kix.mergeEnv {
              inherit who;
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
        # The namespace in the path keeps two instances apart.
        {
          name = "data";
          hostPath = {
            path = "${dataDir}/${scope.namespaceName}-${name}";
            type = "DirectoryOrCreate";
          };
        }
      ];
    };

  # What the kubernetes_logs source watches to put a namespace, labels, and
  # a node on each line. The role name carries the namespace, so two instances
  # never share a ClusterRole.
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
      roles.${"${scope.namespaceName}-${name}"} = grant [
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
