# prometheus-operator: the Prometheus Operator, which reconciles the
# monitoring.coreos.com kinds into Prometheus and Alertmanager StatefulSets
# and their scrape configuration.
#
# Installs the ten monitoring.coreos.com CRDs, vendored under ./crds from the
# release's stripped-down bundle (scripts/vendor-crds.py, `crds/sources.txt`),
# the operator Deployment, its ServiceAccount, the upstream ClusterRole
# (./rbac), and, while `metrics.enabled`, a metrics Service and a
# ServiceMonitor for the operator itself.
#
# Minimal instance:
#
#   instances.monitoring-system.prometheus-operator.package = packages.prometheus-operator;
#
# The operator keeps a Service and Endpoints named `kubelet` in kube-system
# that list every node's kubelet (`--kubelet-service`), so a ServiceMonitor
# can scrape the kubelets. `out.kubeletService` names them.
#
# It injects the config-reloader sidecar (`operandImages.prometheus-config-reloader`)
# into every Prometheus and Alertmanager pod and takes that container's pull
# policy from the Prometheus or Alertmanager resource, so the image's
# `pullPolicy` is refused.
#
# Dependencies:
#   priorityClass (optional)   the operator pod's PriorityClass, read as
#                              `priorityClass.out.name`.
#
# `out`:
#   crds.<Kind>                  the ten CRD handles, for
#                                `scope.mkCR prometheusOperator.out.crds.Prometheus { ... }`.
#                                Prometheus, Alertmanager, PrometheusAgent, and
#                                ThanosRuler declare readiness on Available=True.
#   mkServiceMonitor, mkPodMonitor, mkPrometheusRule, mkProbe
#                                `scope: args:` builders for the four kinds
#                                that the `prometheus` alias promises
#                                (`kix.monitor` calls them, and
#                                victoria-metrics-operator answers the same
#                                names).
#   operandSelectors.{prometheus,alertmanager}
#                                the labels the operator puts on the pods of
#                                a resource, as a function of its name.
#   kubeletService               { namespace; name; labels; } of the kubelet
#                                Service the operator maintains.
#   name, namespace              the operator's, which are also its metrics
#                                Service's (the `job` label of its series).
#   extraImages                  the config-reloader image.
#
# Escape hatches: `extraArgs` and `env` on the operator container, and the
# instance's `partsOverlays` for placement and anything else in the pod spec.
#
# Limits: one replica (`meta.availability.max = "none"`); the operator has no
# leader election. One instance per cluster (`meta.conflictsWith`), because
# the CRDs are cluster-scoped. The operator watches every namespace;
# `--namespaces` in `extraArgs` narrows what it reconciles but not its
# ClusterRole.

{
  scope,
  lib,
  kix,
}:

let
  # The operator, its config-reloader, and the vendored CRDs and ClusterRole
  # come from one upstream release.
  release = "v0.92.1";
  minorOf =
    tag: lib.mapNullable (m: "v${builtins.head m}") (builtins.match "v([0-9]+\\.[0-9]+)(\\..*)?" tag);

  # The labels the operator puts on the pods it creates for a resource,
  # by the resource's name.
  operandSelectors = {
    prometheus = crName: {
      "app.kubernetes.io/name" = "prometheus";
      "operator.prometheus.io/name" = crName;
    };
    alertmanager = crName: {
      "app.kubernetes.io/name" = "alertmanager";
      alertmanager = crName;
    };
  };

  # The operator creates and updates this Service and its Endpoints with one
  # address per node; `--kubelet-service` names it.
  kubeletService = {
    namespace = "kube-system";
    name = "kubelet";
    labels = {
      "app.kubernetes.io/name" = "kubelet";
      "k8s-app" = "kubelet";
    };
  };
in
{
  meta = {
    version = release;
    # The operator has no leader election upstream, so a second replica
    # reconciles everything twice.
    availability.max = "none";
    description = "Prometheus Operator: monitoring.coreos.com CRD controller";
    owner = "platform";
    defaultAliases = [
      "prometheus"
      "prometheusOperator"
    ];
    # The vendored CRDs use CEL validation rules (x-kubernetes-validations),
    # on by default from 1.25.
    k8s.minVersion = "1.25";
    # This package owns the operator.prometheus.io annotation domain (it
    # stamps its CRDs with it); declared for the
    # architecture.annotationDomainOwnership lint (v2_discussions/128).
    annotationDomains = [ "operator.prometheus.io" ];
    # The CRDs are cluster-scoped. Not `cluster:prometheus`, which
    # victoria-metrics-operator also answers.
    conflictsWith = [ "cluster:prometheusOperator" ];
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = minorOf config.image.tag == minorOf release;
        message = "image.tag \"${config.image.tag}\" is not a ${toString (minorOf release)} release (upstream tags look like ${release}), and the CRDs and ClusterRole under kix/packages/prometheus-operator/{crds,rbac} are vendored from ${release}. Remove image.tag or set a ${toString (minorOf release)} tag. To move to another release, change release in kix/packages/prometheus-operator/default.nix and the tag in crds/sources.txt and rbac/sources.txt, then run uv run scripts/vendor-crds.py prometheus-operator.";
      }
      {
        assertion = config.operandImages.prometheus-config-reloader.pullPolicy == null;
        message = "operandImages.prometheus-config-reloader.pullPolicy = \"${toString config.operandImages.prometheus-config-reloader.pullPolicy}\" has no effect: the operator gives the config-reloader sidecar the imagePullPolicy of the Prometheus or Alertmanager resource it runs in. Remove it, and set image.pullPolicy on the prometheus or alertmanager instance instead.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus-operator/prometheus-operator";
      tag = release;
      digest = "sha256:7d9247d2351480fc74587e24681578f815f387bafb2ee7b86a852a94c4cd3774";
    };
    operandImages.prometheus-config-reloader = kix.options.image {
      repository = "quay.io/prometheus-operator/prometheus-config-reloader";
      tag = release;
      tagText = "config.image.tag";
      digest = "sha256:74550ba3e8bf93f47bc574231090d340ae9c01d25cd11ff74799e65f9fdb9a48";
      pullPolicy = null;
      description = "Image the operator injects as the config-reloader sidecar into Prometheus and Alertmanager pods. Its pull policy comes from the Prometheus or Alertmanager resource, so `pullPolicy` must stay null.";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Operator flags appended after the package's, such as `--namespaces=a,b` or `--log-level=debug`. The listen address, `--kubelet-service`, and `--prometheus-config-reloader` are refused: the probes, the Service, `out.kubeletService`, and `operandImages` depend on them.";
    };
    env = kix.options.env;
    metrics = kix.options.monitor // {
      enabled = kix.options.monitor.enabled // {
        description = "Render the operator's metrics Service and a ServiceMonitor for it. Every Prometheus that selects ServiceMonitors in this namespace scrapes it.";
      };
    };
  };

  config =
    { config, ... }:
    {
      operandImages.prometheus-config-reloader.tag = lib.mkDefault config.image.tag;
    };

  build = [
    (import ./crds.nix { inherit operandSelectors; })
    (import ./operator.nix { inherit kubeletService; })
    (
      { self, config, ... }:
      {
        root = {
          resource = self.operatorDeployment;
          requires =
            builtins.attrValues self.crds
            ++ [ self.operatorServiceAccount ]
            ++ builtins.filter (p: p != null) [
              self.operatorService
              self.operatorServiceMonitor
            ];
          out = {
            crds = {
              Alertmanager = self.crds.alertmanagers;
              AlertmanagerConfig = self.crds.alertmanagerConfigs;
              PodMonitor = self.crds.podMonitors;
              Probe = self.crds.probes;
              Prometheus = self.crds.prometheuses;
              PrometheusAgent = self.crds.prometheusAgents;
              PrometheusRule = self.crds.prometheusRules;
              ScrapeConfig = self.crds.scrapeConfigs;
              ServiceMonitor = self.crds.serviceMonitors;
              ThanosRuler = self.crds.thanosRulers;
            };
            mkServiceMonitor = self.crds.serviceMonitors.out.mkCR;
            mkPodMonitor = self.crds.podMonitors.out.mkCR;
            mkPrometheusRule = self.crds.prometheusRules.out.mkCR;
            mkProbe = self.crds.probes.out.mkCR;
            inherit operandSelectors kubeletService;
            namespace = scope.namespaceName;
            extraImages = [ (kix.image.ref config.operandImages.prometheus-config-reloader) ];
          };
        };
      }
    )
  ];
}
