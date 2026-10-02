# loki-logs: every pod's logs into Loki, shipped by a Vector agent on every
# node.
#
# A DaemonSet tails the kubelet's pod log files and pushes each line to the
# Loki instance it depends on, labelled with `namespace`, `pod`,
# `container`, `node`, and `stream`. Files not written for six days are not
# read, since Loki rejects lines older than its 168-hour default.
#
#   instances.logging.loki-logs.package = packages.loki-logs;
#
# Without a `loki` instance in the namespace, auto-instantiation from
# `availablePackages` adds one, and that Loki needs a `storage` claim.
#
# DI deps:
#   loki (required)           an in-cluster Loki; `out.serviceUrl` is the
#                             base URL of its HTTP API
#   priorityClass (optional)  a priority-class instance; the pods run at
#                             its class, and the DaemonSet is ordered after
#                             it. Wire it with deps.priorityClass = ref.<ns>.<name>.
#   prometheus (optional)     ServiceMonitor on Vector's own metrics
#
# Exposes:
#   out.metricsUrl  every agent's Prometheus endpoint, through the headless
#                   metrics Service (root)
#
# Escape hatches: `settings` (Vector's own config, merged over the
# package's; a null removes an unlocked key), `extraArgs`, `env`, and the
# instance's `partsOverlays` for tolerations, extra volumes and the rest.
#
# The agent runs as uid 0 to read the kubelet's log files and mounts host
# paths, so the package declares the `run-as-root` grant and the namespace
# runs at the `privileged` Pod Security level.
#
# The Vector agent itself (image, options, pod spec, RBAC, health check)
# comes from ../clickhouse-logs/vector-agent.nix, which clickhouse-logs
# shares.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "loki-logs ${scope.namespaceName}/${name}";
  vectorAgent = import ../clickhouse-logs/vector-agent.nix { inherit lib kix; };
in
{
  meta = {
    inherit (vectorAgent) version;
    description = "Pod logs into Loki, shipped by a Vector agent on every node";
    owner = "platform";
    # The kubelet writes pod logs as root with mode 0640, so the agent reads
    # them as uid 0, with no capabilities and a read-only root filesystem.
    unsafe = [ "run-as-root" ];
    # hostPath volumes (the node's /var/log and the read positions), which
    # the baseline Pod Security level forbids.
    podSecurity = "privileged";
  };

  options = vectorAgent.options // {
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        sinks.loki.tenant_id = "team-a";
        sources.kubernetes_logs.extra_namespace_label_selector = "logs!=off";
      };
      description = ''
        Vector configuration merged over the package's own: sources
        `kubernetes_logs` and `internal_metrics`, sinks `loki` and `metrics`.
        A null removes a key the package sets, such as one of the
        `sinks.loki.labels`. The package locks `sinks.loki.endpoint`
        (follows `deps.loki`), and `sinks.loki.type`, `sinks.metrics`,
        `sources.internal_metrics`, and `data_dir` (they feed the probes, the
        metrics Service, and the health check); setting one, or replacing a
        key above it, fails evaluation.
      '';
    };

    metrics = kix.options.monitor;
    healthCheck = kix.options.healthCheck;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        loki,
        priorityClass ? null,
        ...
      }:
      let
        lokiUrl =
          loki.out.serviceUrl
            or (throw "${who}: deps.loki resolved to an instance with no out.serviceUrl (the base URL of Loki's HTTP API), so the agent has nowhere to push. Point deps.loki at a loki instance.");

        builtinSettings = lib.recursiveUpdate vectorAgent.baseConfig {
          # Loki rejects lines older than reject_old_samples_max_age (168h
          # by default) with a 400, and Vector drops them as sink errors. A
          # file not written for six days holds only such lines, so it is
          # not read.
          sources.kubernetes_logs.ignore_older_secs = 6 * 24 * 3600;
          sinks.loki = {
            type = "loki";
            inputs = [ "kubernetes_logs" ];
            # Base URL; Vector appends `path` (/loki/api/v1/push). It
            # carries the loki Service's context, so the ConfigMap gives
            # the ordering and network-policy edge.
            endpoint = lokiUrl;
            encoding.codec = "text";
            # Fields every kubernetes_logs event has. A template that fails
            # to render is a sink error, so no label reads an optional pod
            # label.
            labels = {
              namespace = "{{ kubernetes.pod_namespace }}";
              pod = "{{ kubernetes.pod_name }}";
              container = "{{ kubernetes.container_name }}";
              node = "{{ kubernetes.pod_node_name }}";
              stream = "{{ stream }}";
            };
          };
        };

        mergedSettings = vectorAgent.mergeConfig {
          inherit who;
          sink = "loki";
        } builtinSettings config.settings;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."vector.yaml" = builtins.toJSON mergedSettings;
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        configMount = kix.mount.configMap self.configMap {
          mountPath = "/etc/vector";
          readOnly = true;
        };

        daemonSet =
          {
            inherit name;
            labels."app.kubernetes.io/name" = "vector";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/config" = self.configMap.out.identityHash;
                spec =
                  vectorAgent.podSpec {
                    inherit
                      scope
                      who
                      name
                      config
                      self
                      ;
                  }
                  // lib.optionalAttrs (priorityClass != null) {
                    priorityClassName = priorityClass.out.name;
                  };
              };
            };
          }
          |> kix.withMounts [ self.configMount ]
          |> scope.mkDaemonSet;

        # Headless, so the health check reaches every agent. It is the
        # root, and renders without a prometheus dependency.
        service =
          self.daemonSet
          |> kix.service.fromWorkload {
            name = "${name}-metrics";
            spec.clusterIP = "None";
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          out.metricsUrl = "${self.service.out.url { }}/metrics";
        };
      }
      // vectorAgent.rbac { inherit scope self name; }
    )

    (kix.monitor {
      service = "service";
      port = "metrics";
    })

    (vectorAgent.healthCheck { sink = "loki"; })
  ];
}
