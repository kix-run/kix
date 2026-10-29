# victoria-metrics-operator: VictoriaMetrics operator, the drop-in
# monitoring provider behind the `prometheus` alias.
#
# Manages operator.victoriametrics.com CRDs (VMCluster, VMAgent, VMAlert,
# VMAlertmanager, VMServiceScrape, VMPodScrape, VMRule, VMProbe) and
# natively converts prometheus-operator objects into VM equivalents. This
# package ships the prometheus-operator compat CRDs (ServiceMonitor,
# PodMonitor, PrometheusRule, Probe; CRDs only, no second controller) and
# exposes the same builder surface as the prometheus-operator package, so
# every existing kix.monitor call and app-package ServiceMonitor works
# unchanged when this package holds the `prometheus` alias.
#
# No conflictsWith entry for prometheus-operator: mixed clusters are
# legitimate, and DI ambiguity on the `prometheus` alias is the guard
# against wiring both at once.
#
# Exposes CRD builder functions via `out`:
#   out.mkServiceMonitor / mkPodMonitor / mkPrometheusRule / mkProbe
#     prometheus-operator-compatible CRs (converted by the operator)
#   out.mkVMCluster / mkVMAgent / mkVMAlert / mkVMAlertmanager
#     used by the victoria-metrics-{cluster,agent,alert} packages
#   out.mkVMServiceScrape / mkVMPodScrape / mkVMRule / mkVMProbe
#     native scrape/rule CRs
#
# Alerts (a VMRule `<instance>-alerts`, which vmalert evaluates and a
# prometheus-operator Prometheus does not load). They render with
# `metrics.enabled` on:
#   VMOperatorDown             down, warning: running operands keep
#                              working, but no CR change is applied
#   VMOperatorReconcileErrors  stuck state, warning
# The operator's metrics reach the store only through a vmagent that
# selects its VMServiceScrape.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  inherit (import ./kinds.nix) promCompatDefs;
in

{
  meta = {
    version = "v0.74.1";
    description = "VictoriaMetrics Operator: operator.victoriametrics.com CRD controller";
    owner = "platform";
    defaultAliases = [
      "prometheus"
      "vmOperator"
    ];
    k8s.minVersion = "1.25";
    # This package owns the operator.victoriametrics.com annotation domain
    # (it stamps its CRDs with it); declared for the
    # architecture.annotationDomainOwnership lint.
    annotationDomains = [ "operator.victoriametrics.com" ];
  };

  options = {
    image = kix.options.image {
      repository = "victoriametrics/operator";
      tag = "v0.74.1";
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      # The operator runs with --leader-elect, so a restart is invisible and
      # "pod" stays at 1; from "node" up a standby covers a lost node.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of operator replicas. Defaults from the cluster's
        availability level.
      '';
    };
    resources = kix.options.resources {
      requests = {
        cpu = "80m";
        memory = "120Mi";
      };
      limits = {
        cpu = "500m";
        memory = "320Mi";
      };
    };
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Value for --zap-log-level.";
    };
    # Self-monitoring: the operator auto-creates scrapes for its operands
    # but never for its own Deployment; this emits a VMServiceScrape for
    # the operator's metrics Service.
    metrics = kix.options.monitor;
    # Which prometheus-operator kinds the built-in converter turns into
    # VM equivalents. One option per converter the operator has, generated
    # from the same table that decides which compat CRDs ship
    # (kinds.nix promCompatDefs), so a converter can never be switched on
    # for a kind whose CRD is absent.
    #
    # The four with an out.mk* builder default on, which is what makes
    # this package a drop-in for prometheus-operator. The two without one
    # default off: turning one on adds its CRD, and a cluster with no
    # ScrapeConfigs has no use for the machinery.
    #
    # Turn a converter off where the VM side has no consumer for the
    # result. Running VM beside Prometheus with no vmalert, for instance,
    # converts every PrometheusRule on the cluster into a VMRule that
    # nothing evaluates, and those land in whatever namespace the source
    # lives in. Turning one off does not delete what it already
    # converted; the operator stops reconciling that kind and leaves the
    # objects behind.
    convert = lib.mapAttrs (
      _: def:
      lib.mkOption {
        type = lib.types.bool;
        default = def.convertByDefault;
        description = "Convert ${def.kind} to its VictoriaMetrics equivalent.";
      }
    ) promCompatDefs;

    converterOwnerReferences = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, converted VM objects get ownerReferences to their
        prometheus-operator sources so Kubernetes GC removes them together
        (VM_ENABLEDPROMETHEUSCONVERTEROWNERREFERENCES). Upstream default is
        false: the operator tracks and deletes converted objects itself.
      '';
    };
    # Who installs the four prometheus-operator CRDs the converter watches
    # (ServiceMonitor, PodMonitor, PrometheusRule, Probe).
    #
    # "declare" ships them from this package, as the slim schemas below.
    # That is right where VictoriaMetrics is the only monitoring stack on
    # the cluster.
    #
    # "reference" is for a cluster that already has them: prometheus-
    # operator itself, usually installed by Helm. Kix emits an import
    # marker per CRD and waits for it to be Established instead of
    # declaring it. Deploying "declare" onto such a cluster stops on a
    # field-ownership conflict, because Kix's `.spec.versions` collides
    # with the real one and helm and kubectl own it. Forcing that conflict
    # would replace the upstream schemas with stubs for every
    # ServiceMonitor on the cluster, so there is no safe default here to
    # guess: say which cluster you are on.
    #
    # `out.mkServiceMonitor` and its siblings work the same either way:
    # mkCRDRef returns the same builders mkCRD does. Choosing "reference"
    # on a cluster that does NOT have the CRDs makes the deploy wait for
    # them and time out, which is the visible failure, preferred over
    # installing a second opinion about the schema.
    prometheusOperatorCRDs = lib.mkOption {
      type = lib.types.enum [
        "declare"
        "reference"
      ];
      default = "declare";
      description = ''
        Whether this package declares the prometheus-operator compat CRDs
        or references ones already installed on the cluster.
      '';
    };
    watchNamespaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "If non-empty, sets WATCH_NAMESPACE to restrict the operator's scope.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to the operator container's args.";
    };
    env = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra env entries merged into the operator container env.";
    };
    tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    affinity = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    imagePullSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    serviceAccountAnnotations = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra fields deep-merged into the Deployment spec via
        lib.recursiveUpdate. Escape hatch for fields not exposed as typed
        options.
      '';
    };
  };

  build = [
    ./crds.nix
    ./operator.nix
    (
      {
        self,
        config,
        lib,
        kix,
        ...
      }:
      let
        # Wrap `mkCR` with `scrapeJob` and `replicas` outputs. Operand pods
        # are scraped under job "<prefix>-<CR name>" and there are
        # spec.replicaCount of them. Stated on the CR's `out` so a consumer
        # (the sibling packages' probes) reads it off the resource instead
        # of retyping the convention. Structural: reading a count is not
        # dialing anything.
        mkOperand =
          prefix: mkCR: consumerScope: args:
          mkCR consumerScope (
            args
            // {
              outputs = {
                scrapeJob = kix.facts.structural "${prefix}-${args.name}";
                replicas = kix.facts.structural (toString (args.spec.replicaCount or 1));
              }
              // (args.outputs or { });
            }
          );
      in
      {
        root = {
          resource = self.operatorDeployment;
          requires =
            # Every shipped CRD (deployed in early waves before the operator
            # starts), derived so a new kinds.nix entry is auto-included.
            builtins.attrValues self.crds
            # Operator resources
            ++ [
              self.operatorServiceAccount
              self.operatorService
            ]
            ++ lib.optional config.metrics.enabled self.operatorServiceScrape
            ++ lib.optional (self.prometheusRules != null) self.prometheusRules;

          # Expose CRD builders; packages depend on these via DI
          # Usage: prometheus.out.mkServiceMonitor scope { ... }
          out = {
            inherit (self.crds.serviceMonitors.out) mkCR;
            # prometheus-operator-compatible surface (converter input)
            mkServiceMonitor = self.crds.serviceMonitors.out.mkCR;
            mkPodMonitor = self.crds.podMonitors.out.mkCR;
            mkPrometheusRule = self.crds.prometheusRules.out.mkCR;
            mkProbe = self.crds.probes.out.mkCR;
            # VM-native surface (sibling packages)
            mkVMCluster = self.crds.vmClusters.out.mkCR;
            mkVMAgent = mkOperand "vmagent" self.crds.vmAgents.out.mkCR;
            mkVMAlert = mkOperand "vmalert" self.crds.vmAlerts.out.mkCR;
            mkVMAlertmanager = mkOperand "vmalertmanager" self.crds.vmAlertmanagers.out.mkCR;
            mkVMServiceScrape = self.crds.vmServiceScrapes.out.mkCR;
            mkVMPodScrape = self.crds.vmPodScrapes.out.mkCR;
            mkVMRule = self.crds.vmRules.out.mkCR;
            mkVMProbe = self.crds.vmProbes.out.mkCR;
            # Kinds marked indexer-floor-only in kinds.nix (VMScrapeConfig,
            # VMUser, ...) get no builders until a consumer appears.
            # The operator injects its config-reloader sidecar into vmagent /
            # vmalert / vmalertmanager pods, not in any Kix-generated
            # manifest. Default image per upstream internal/config/config.go.
            extraImages = [
              "victoriametrics/operator:config-reloader-${config.image.tag}"
            ];
          };
        };
      }
    )

    # This package is the `prometheus` provider, so it cannot take one as a
    # dependency. kix.alerts gets this package's VMRule builder in the place
    # of a PrometheusRule builder; the two kinds take the same `groups`.
    (
      {
        self,
        config,
        scope,
        ...
      }@args:
      let
        ns = scope.namespaceName;
        # The VMServiceScrape `<instance>-monitor` sets `job` to the
        # operator's Service name, which is the instance name (operator.nix).
        op = ''namespace="${ns}",job="${scope.instanceName}"'';
      in
      kix.alerts
        {
          alerts = {
            VMOperatorDown = {
              expr = "sum by (namespace, job) (up{${op}}) == 0 or absent(up{${op}})";
              "for" = "10m";
              severity = "warning";
              summary = "The VictoriaMetrics operator is down.";
              description = "No replica of the VictoriaMetrics operator ${ns}/${scope.instanceName} has answered a scrape for 10 minutes. Running VMCluster, VMAgent, and VMAlert workloads keep working, but no change to a VictoriaMetrics CR, ServiceMonitor, or PrometheusRule is applied. Check the operator Deployment.";
            };
            VMOperatorReconcileErrors = {
              expr = "sum by (namespace, job, controller) (rate(controller_runtime_reconcile_errors_total{${op}}[5m])) > 0";
              "for" = "15m";
              severity = "warning";
              summary = "The VictoriaMetrics operator fails to reconcile objects.";
              description = "The {{ $labels.controller }} controller of the VictoriaMetrics operator ${ns}/${scope.instanceName} has failed reconciles for 15 minutes, so the objects it manages may not match their CRs. Check the operator logs for the object and the error.";
            };
          };
        }
        (
          args
          // {
            prometheus.out.mkPrometheusRule = self.crds.vmRules.out.mkCR;
          }
        )
    )
  ];
}
