# VictoriaMetrics Operator: deployment, service, RBAC.
#
# The operator watches operator.victoriametrics.com CRDs and reconciles
# them into running workloads, and converts prometheus-operator objects
# (ServiceMonitor, PodMonitor, PrometheusRule, Probe) into VM equivalents.
#
# RBAC is curated from the upstream chart's role.yaml (victoria-metrics-
# operator 0.67.x, operator v0.74.1). The wide core/apps/rbac grants are
# required: the operator creates operand workloads, their Services,
# ServiceAccounts, and per-operand RBAC. K8s escalation prevention means
# the operator must itself hold everything it grants (nodes, /metrics
# nonResourceURLs, and endpointslices are what vmagent's scrape RBAC needs).

{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  labels = {
    "app.kubernetes.io/name" = "victoria-metrics-operator";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/part-of" = "victoria-metrics-operator";
    "app.kubernetes.io/version" = builtins.unsafeDiscardStringContext config.image.tag;
  };

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    full
    mkClusterRoleSet
    mkRoleSet
    ;

  vmGroup = group "operator.victoriametrics.com" [ ];
  # RBAC plurals derive from the same table as the CRDs (kinds.nix), so
  # shipping a CRD and granting the operator access to it cannot drift.
  vmResources = lib.mapAttrsToList (_: def: def.plural) (import ./kinds.nix).vmCrdDefs;
  # Upstream grants * on <plural>, <plural>/finalizers, <plural>/status for
  # every CRD the chart ships; mirror that shape for the kinds we ship.
  vmKindRules = lib.concatMap (r: [
    (vmGroup r |> full)
    (vmGroup "${r}/finalizers" |> allow [ "update" ])
    (
      vmGroup "${r}/status"
      |> allow [
        "get"
        "patch"
        "update"
      ]
    )
  ]) vmResources;

  # Same table as the compat CRDs (kinds.nix), for the same reason as
  # vmResources above: a converter the operator may run and a grant to
  # read its input cannot drift apart. Granted for every kind in the
  # table rather than only the enabled ones, so flipping a converter on
  # does not also need an RBAC change.
  promCompat = group "monitoring.coreos.com" promCompatPlurals;
  promCompatPlurals = lib.mapAttrsToList (_: def: def.plural) (import ./kinds.nix).promCompatDefs;
  # One grant per kind in the table. Listing them by hand here is what let
  # the table grow two entries while the ClusterRole kept the original
  # four, so the operator watched ScrapeConfig and was refused: a slow
  # crashloop with the real cause six lines deep in the log.
  promCompatRules = map (plural: promCompat.${plural} |> full) promCompatPlurals;
  apps = group "apps" [
    "daemonsets"
    "deployments"
    "replicasets"
    "statefulsets"
  ];
  rbacGroup = group "rbac.authorization.k8s.io" [
    "clusterrolebindings"
    "clusterroles"
    "rolebindings"
    "roles"
  ];
  policy = group "policy" [ "poddisruptionbudgets" ];
  autoscaling = group "autoscaling" [ "horizontalpodautoscalers" ];
  net = group "networking.k8s.io" [
    "ingresses"
    "networkpolicies"
  ];
  storage = group "storage.k8s.io" [ "storageclasses" ];
  # Legacy + OpenShift groups: the operator writes them into vmagent's
  # scrape ClusterRole verbatim, and K8s escalation prevention refuses the
  # write unless the operator itself holds them ("attempting to grant RBAC
  # permissions not currently held"). They are inert on non-OpenShift
  # clusters but must be granted.
  legacyExt = group "extensions" [ "ingresses" ];
  openshiftRoute = group "route.openshift.io" [
    "routers/metrics"
    "registry/metrics"
  ];
  openshiftImage = group "image.openshift.io" [
    "routers/metrics"
    "registry/metrics"
  ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];

  mkSubject = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];

  operatorClusterRoles = mkClusterRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}" =
        grant (
          vmKindRules
          # Converter input: prometheus-operator compat objects, every
          # kind in the table whether or not its converter is enabled, so
          # flipping one on needs no RBAC change.
          ++ promCompatRules
          ++ [
            # Core resources the operator manages for operands
            (core.configmaps |> full)
            (core "configmaps/finalizers" |> allow [ "update" ])
            (core "configmaps/status" |> watch)
            (core.endpoints |> full)
            (core.events |> full)
            (core.persistentvolumeclaims |> full)
            (core "persistentvolumeclaims/finalizers" |> allow [ "update" ])
            (core.pods |> full)
            (core "pods/eviction" |> allow [ "create" ])
            (core.secrets |> full)
            (core "secrets/finalizers" |> allow [ "update" ])
            (core.services |> full)
            (core "services/finalizers" |> allow [ "update" ])
            (core.serviceaccounts |> full)
            (core "serviceaccounts/finalizers" |> allow [ "update" ])
            (core.namespaces |> watch)
            (core.nodes |> watch)
            (core "nodes/metrics" |> watch)

            # Operand workloads
            (apps.daemonsets |> full)
            (apps "daemonsets/finalizers" |> allow [ "update" ])
            (apps.deployments |> full)
            (apps "deployments/finalizers" |> allow [ "update" ])
            (apps.replicasets |> full)
            (apps.statefulsets |> full)
            (apps "statefulsets/finalizers" |> allow [ "update" ])
            (
              apps "statefulsets/status"
              |> allow [
                "get"
                "patch"
                "update"
              ]
            )

            # Per-operand RBAC (e.g. vmagent's scrape ClusterRole)
            (rbacGroup.clusterrolebindings |> full)
            (rbacGroup "clusterrolebindings/finalizers" |> allow [ "update" ])
            (rbacGroup.clusterroles |> full)
            (rbacGroup "clusterroles/finalizers" |> allow [ "update" ])
            (rbacGroup.roles |> full)
            (rbacGroup.rolebindings |> full)

            (policy.poddisruptionbudgets |> full)
            (policy "poddisruptionbudgets/finalizers" |> allow [ "update" ])
            (autoscaling.horizontalpodautoscalers |> full)
            (net.ingresses |> full)
            (net "ingresses/finalizers" |> allow [ "update" ])
            (net.networkpolicies |> full)
            (storage.storageclasses |> watch)
            (
              apiext.customresourcedefinitions
              |> allow [
                "get"
                "list"
              ]
            )
            (discovery.endpointslices |> watch)

            # See legacyExt/openshift* note above: vmagent-role grants.
            (legacyExt.ingresses |> watch)
            (openshiftRoute."routers/metrics" |> allow [ "get" ])
            (openshiftRoute."registry/metrics" |> allow [ "get" ])
            (openshiftImage."routers/metrics" |> allow [ "get" ])
            (openshiftImage."registry/metrics" |> allow [ "get" ])
          ]
        )
        # Scrape targets exposed only as raw HTTP paths (kubelet metrics);
        # granted so the operator can pass them on to vmagent's ClusterRole.
        ++ [
          {
            nonResourceURLs = [
              "/metrics"
              "/metrics/resources"
              "/metrics/slis"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
        ];
    };
  };

  # Namespace-scoped RBAC for leader election.
  operatorLeaderElection = mkRoleSet scope {
    subjects = mkSubject self.operatorServiceAccount;
    labels = labels;
    roles = {
      "${name}:leader-election" = grant [
        (
          coord.leases
          |> allow [
            "create"
            "get"
            "update"
          ]
        )
      ];
    };
  };
in
{
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
          name = "http";
          port = 8080;
          targetPort = 8080;
        }
      ];
    };
    outputs = {
      metricsPort = "8080";
    };
  };

  # Self-scrape via this package's own builder; the operator only
  # auto-scrapes its operands, never its own Deployment.
  operatorServiceScrape =
    if config.metrics.enabled then
      self.crds.vmServiceScrapes.out.mkCR scope {
        name = "${name}-monitor";
        spec = {
          selector.matchLabels = self.operatorService.out.selector;
          endpoints = [
            (
              {
                port = "http";
                path = "/metrics";
              }
              // lib.optionalAttrs (config.metrics.interval or null != null) {
                inherit (config.metrics) interval;
              }
            )
          ];
        };
      }
    else
      null;

  operatorDeployment =
    let
      args = [
        "--zap-log-level=${config.logLevel}"
        "--leader-elect"
        "--health-probe-bind-address=:8081"
      ]
      ++ config.extraArgs;

      # The prometheus-operator converter is the compat contract for the
      # `prometheus` alias claim: every converter is pinned explicitly from
      # the `convert` options. Those decide which compat CRDs crds.nix
      # renders, so the operator can never be told to watch a CRD that is
      # not here.
      env = [
        {
          name = "POD_NAME";
          valueFrom.fieldRef.fieldPath = "metadata.name";
        }
        {
          name = "OPERATOR_NAME";
          value = "victoria-metrics-operator";
        }
        {
          name = "VM_ENABLEDPROMETHEUSCONVERTEROWNERREFERENCES";
          value = lib.boolToString config.converterOwnerReferences;
        }
      ]
      ++ lib.mapAttrsToList (name: def: {
        name = "VM_ENABLEDPROMETHEUSCONVERTER_${def.env}";
        value = lib.boolToString config.convert.${name};
      }) (import ./kinds.nix).promCompatDefs
      ++ lib.optional (config.watchNamespaces != [ ]) {
        name = "WATCH_NAMESPACE";
        value = lib.concatStringsSep "," config.watchNamespaces;
      }
      ++ config.env;

      probeTimings = {
        initialDelaySeconds = 5;
        periodSeconds = 15;
        timeoutSeconds = 5;
        failureThreshold = 3;
      };

      container = {
        name = "operator";
        image = kix.image.ref config.image;
        imagePullPolicy = config.image.pullPolicy;
        inherit args env;
        ports = [
          (kix.port "http" 8080)
          (kix.port "probe" 8081)
        ];
        readinessProbe = {
          httpGet = {
            path = "/health";
            port = "probe";
            scheme = "HTTP";
          };
        }
        // probeTimings;
        livenessProbe = {
          tcpSocket.port = "probe";
        }
        // probeTimings;
        securityContext = {
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          runAsNonRoot = true;
          capabilities.drop = [ "ALL" ];
        };
        resources = config.resources;
      };

      podSpec = {
        serviceAccountName = self.operatorServiceAccount.out.name;
        automountServiceAccountToken = true;
        terminationGracePeriodSeconds = 30;
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          fsGroup = 2000;
          seccompProfile.type = "RuntimeDefault";
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
      };

      baseSpec = {
        replicas = config.replicas;
        selector.matchLabels = {
          "app.kubernetes.io/name" = "victoria-metrics-operator";
          "app.kubernetes.io/instance" = name;
        };
        template = {
          metadata.labels = labels;
          spec = podSpec;
        };
      };
    in
    {
      name = name;
      inherit labels;
      spec = lib.recursiveUpdate baseSpec config.extraSpec;
    }
    |> scope.mkDeployment;
}
// operatorClusterRoles
// operatorLeaderElection
