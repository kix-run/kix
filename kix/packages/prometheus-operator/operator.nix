# Prometheus Operator — deployment, service, RBAC.
#
# The operator watches monitoring.coreos.com CRDs (Prometheus, Alertmanager,
# ServiceMonitor, etc.) and reconciles them into running workloads.

{
  self,
  config,
  scope,
  lib,
  ...
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  labels = {
    "app.kubernetes.io/name" = "prometheus-operator";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/part-of" = "prometheus-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  inherit (scope.rbac)
    group
    core
    grant
    watch
    reconcile
    readWrite
    full
    allow
    emit
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;

  # API groups the operator manages
  mon = group "monitoring.coreos.com" [
    "alertmanagerconfigs"
    "alertmanagers"
    "alertmanagers/finalizers"
    "alertmanagers/status"
    "podmonitors"
    "probes"
    "prometheusagents"
    "prometheuses"
    "prometheuses/finalizers"
    "prometheuses/status"
    "prometheusrules"
    "scrapeconfigs"
    "servicemonitors"
    "thanosrulers"
    "thanosrulers/finalizers"
  ];
  apps = group "apps" [
    "statefulsets"
    "deployments"
    "daemonsets"
  ];
  net = group "networking.k8s.io" [ "ingresses" ];
  coord = group "coordination.k8s.io" [ "leases" ];
  authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];
  events = group "events.k8s.io" [ "events" ];
  storage = group "storage.k8s.io" [ "storageclasses" ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];

  mkSubject = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];

  # ── Cluster RBAC ─────────────────────────────────────────────────────

  operatorClusterRoles = mkClusterRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}" = grant [
        # Full access to all monitoring CRDs
        (mon.alertmanagerconfigs |> reconcile)
        (mon.alertmanagers |> reconcile)
        (mon "alertmanagers/finalizers" |> allow [ "update" ])
        (
          mon "alertmanagers/status"
          |> allow [
            "get"
            "update"
          ]
        )
        (mon.podmonitors |> watch)
        (mon.probes |> watch)
        (mon.prometheusagents |> reconcile)
        (mon.prometheuses |> reconcile)
        (mon "prometheuses/finalizers" |> allow [ "update" ])
        (
          mon "prometheuses/status"
          |> allow [
            "get"
            "update"
          ]
        )
        (mon.prometheusrules |> watch)
        (mon.scrapeconfigs |> watch)
        (mon.servicemonitors |> watch)
        (mon.thanosrulers |> reconcile)
        (mon "thanosrulers/finalizers" |> allow [ "update" ])

        # Core resources the operator manages (creates Services, Secrets,
        # ConfigMaps for Prometheus/Alertmanager instances)
        (core.configmaps |> full)
        (core.secrets |> full)
        (core.services |> full)
        (
          core "services/finalizers"
          |> allow [
            "get"
            "create"
            "update"
            "delete"
          ]
        )
        (core.endpoints |> full)
        (
          core.pods
          |> allow [
            "list"
            "delete"
          ]
        )
        (core.namespaces |> watch)
        (core.nodes |> watch)
        (core.events |> emit)
        (events.events |> emit)

        # Apps — the operator creates StatefulSets for Prometheus/Alertmanager
        (apps.statefulsets |> full)
        (apps.deployments |> full)
        (apps.daemonsets |> full)

        # Networking
        (net.ingresses |> watch)

        # Storage class lookup for VolumeClaimTemplate provisioning
        (storage.storageclasses |> allow [ "get" ])

        # EndpointSlice discovery (modern target enumeration path)
        (discovery.endpointslices |> readWrite)

        # Webhook validation
        (authz.subjectaccessreviews |> allow [ "create" ])
      ];
    };
  };

  # ── Namespace-scoped RBAC (leader election) ──────────────────────────

  operatorLeaderElection = mkRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}:leader-election" = grant [
        (
          coord.leases
          |> restrictTo [ "prometheus-operator" ]
          |> allow [
            "get"
            "update"
            "patch"
          ]
        )
        (coord.leases |> allow [ "create" ])
        (
          core.configmaps
          |> allow [
            "get"
            "list"
            "watch"
            "create"
            "update"
            "patch"
            "delete"
          ]
        )
        (
          core.events
          |> allow [
            "create"
            "patch"
          ]
        )
      ];
    };
  };

in
{
  # ── ServiceAccount ───────────────────────────────────────────────────

  operatorServiceAccount = scope.mkResource (
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = name;
      inherit labels;
      extra.automountServiceAccountToken = true;
    }
    // lib.optionalAttrs (config.serviceAccountAnnotations != { }) {
      annotations = config.serviceAccountAnnotations;
    }
  );

  # ── Service ──────────────────────────────────────────────────────────

  operatorService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = name;
    inherit labels;
    spec = {
      type = "ClusterIP";
      selector = self.operatorDeployment.out.selector;
      ports = [
        {
          name = "http-metrics";
          port = 8080;
          targetPort = 8080;
        }
      ];
    };
    outputs = {
      metricsPort = "8080";
    };
  };

  # ── Deployment ───────────────────────────────────────────────────────

  operatorDeployment =
    let
      kubeletArg = lib.optional config.kubeletService.enabled (
        "--kubelet-service=${config.kubeletService.namespace}/${config.kubeletService.name}"
      );
      baseArgs = kubeletArg ++ [
        "--prometheus-config-reloader=${config.prometheusConfigReloader.image.repository}:${config.prometheusConfigReloader.image.tag}"
      ];
      finalArgs =
        baseArgs
        ++ lib.optional (
          config.denyNamespaces != [ ]
        ) "--deny-namespaces=${lib.concatStringsSep "," config.denyNamespaces}"
        ++ lib.optional (
          config.namespaces != [ ]
        ) "--namespaces=${lib.concatStringsSep "," config.namespaces}"
        ++ config.extraArgs;

      mkProbe =
        cfg:
        {
          httpGet = {
            path = "/healthz";
            port = "http-metrics";
          };
          inherit (cfg) periodSeconds failureThreshold;
        }
        // lib.optionalAttrs (cfg.initialDelaySeconds or null != null) {
          inherit (cfg) initialDelaySeconds;
        }
        // lib.optionalAttrs (cfg.timeoutSeconds != null) {
          inherit (cfg) timeoutSeconds;
        }
        // lib.optionalAttrs (cfg.successThreshold != null) {
          inherit (cfg) successThreshold;
        }
        // lib.optionalAttrs (cfg.failureThreshold or null == null) {
          # Chart leaves failureThreshold unset on readinessProbe; mirror.
        };

      container = {
        name = "prometheus-operator";
        image = "${config.image.repository}:${config.image.tag}";
        imagePullPolicy = config.image.pullPolicy;
        args = finalArgs;
        ports = [
          {
            name = "http-metrics";
            containerPort = 8080;
          }
        ];
        securityContext = {
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilities.drop = [ "ALL" ];
        };
        resources = config.resources;
      }
      // lib.optionalAttrs config.livenessProbe.enabled {
        livenessProbe = mkProbe config.livenessProbe;
      }
      // lib.optionalAttrs config.readinessProbe.enabled {
        readinessProbe = mkProbe config.readinessProbe;
      }
      // lib.optionalAttrs (config.lifecycle != null) {
        lifecycle = config.lifecycle;
      }
      // lib.optionalAttrs (config.env != [ ]) { env = config.env; }
      // lib.optionalAttrs (config.extraVolumeMounts != [ ]) {
        volumeMounts = config.extraVolumeMounts;
      };

      podSpec = {
        serviceAccountName = self.operatorServiceAccount.out.name;
        automountServiceAccountToken = true;
        inherit (config) terminationGracePeriodSeconds;
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 65534;
          runAsGroup = 65534;
          fsGroup = 65534;
        };
        containers = [ container ];
        nodeSelector = {
          "kubernetes.io/os" = "linux";
        }
        // config.nodeSelector;
      }
      // lib.optionalAttrs (config.tolerations != [ ]) { tolerations = config.tolerations; }
      // lib.optionalAttrs (config.affinity != { }) { affinity = config.affinity; }
      // lib.optionalAttrs (config.priorityClassName != null) {
        priorityClassName = config.priorityClassName;
      }
      // lib.optionalAttrs (config.imagePullSecrets != [ ]) {
        imagePullSecrets = config.imagePullSecrets;
      }
      // lib.optionalAttrs config.hostNetwork {
        hostNetwork = true;
        dnsPolicy = "ClusterFirstWithHostNet";
      }
      // lib.optionalAttrs (config.dnsConfig != null) {
        dnsConfig = config.dnsConfig;
      }
      // lib.optionalAttrs (config.extraVolumes != [ ]) { volumes = config.extraVolumes; };

      baseSpec = {
        replicas = config.replicas;
        selector.matchLabels = {
          "app.kubernetes.io/name" = "prometheus-operator";
          "app.kubernetes.io/instance" = name;
        };
        template = {
          metadata.labels = labels;
          spec = podSpec;
        };
      };

      finalSpec = lib.recursiveUpdate baseSpec config.extraSpec;
    in
    {
      name = name;
      inherit labels;
      spec = finalSpec;
    }
    |> scope.mkDeployment;
}
// operatorClusterRoles
// operatorLeaderElection
