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
#   instances.monitoring-system.prometheus-operator.package = packages.experimental.prometheus-operator;
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
#   version                      the operator version `image.tag` names.
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
# `extraArgs` refuses `--kubelet-endpointslice`, which needs EndpointSlice
# access the vendored ClusterRole does not grant.
#
# Alerts: none in this package. prometheus-default-rules vendors upstream's
# `prometheus-operator` rule group, scoped to this operator's metrics
# Service: reconcile, sync, list, watch, and status-update errors, resources
# the operator rejects (PrometheusOperatorRejectedResources), and the
# operator not ready. Its TargetDown covers the operator not answering a
# scrape, so the operator's alerts need that package.
#
# Upgrades: v0.95.2 takes over directly from v0.92.1. It reconciles the
# Prometheus and Alertmanager resources the old operator left, and they stay
# Available. Both get the new config-reloader image, so the operator restarts
# every Prometheus and Alertmanager pod once. Data on their claims survives
# the restart. Going back works too. `kix rollback`, or deploying the v0.92.1
# package, puts the old operator and CRDs back. The old operator reconciles
# the same resources and restarts the pods once more. Upstream gives no
# upgrade or downgrade policy beyond the CHANGE entries in its release notes.
# From v0.93.0 the CRDs refuse negative values in fields such as
# `sampleLimit`, `labelLimit`, and `modulus`. From v0.93.0 a Thanos sidecar
# that uploads to object storage no longer turns off local compaction
# (`spec.disableCompaction: true` restores that).
#
# Limits: one replica (`meta.availability.max = "none"`); the operator has no
# leader election. The operator watches every namespace; `--namespaces` in
# `extraArgs` narrows what it reconciles but not its ClusterRole. Two
# instances in one build render the same CRDs, which fails evaluation.

{
  scope,
  lib,
  kix,
}:

let
  # The operator, its config-reloader, and the vendored CRDs and ClusterRole
  # come from one upstream release.
  release = "v0.95.2";
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
    version = lib.removePrefix "v" release;
    # The operator has no leader election upstream, so a second replica
    # reconciles everything twice.
    availability.max = "none";
    description = "Prometheus Operator: monitoring.coreos.com CRD controller";
    owner = "platform";
    defaultAliases = [
      "prometheus"
      "prometheusOperator"
    ];
    # One operator watches every namespace, so consumers in any namespace
    # find it by name.
    scope = "cluster";
    # Upstream's compatibility page (Documentation/getting-started/compatibility.md)
    # requires 1.25, because the CRDs use CEL validation rules. It states no
    # newest version, so the package sets no upper bound.
    k8s = {
      minVersion = "1.25";
      reason = "prometheus-operator ${release} requires Kubernetes 1.25 or later";
    };
    # This package owns the operator.prometheus.io annotation domain (it
    # stamps its CRDs with it); declared for the
    # architecture.annotationDomainOwnership lint.
    annotationDomains = [ "operator.prometheus.io" ];
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = minorOf imageTag == minorOf release;
        message = "image.tag \"${imageTag}\" is not a ${toString (minorOf release)} release (upstream tags look like ${release}), and the CRDs and ClusterRole under kix/packages/experimental/prometheus-operator/{crds,rbac} are vendored from ${release}. Remove image.tag or set a ${toString (minorOf release)} tag. To move to another release, change release in kix/packages/experimental/prometheus-operator/default.nix and the tag in crds/sources.txt and rbac/sources.txt, then run uv run scripts/vendor-crds.py prometheus-operator.";
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
      digest = "sha256:7986c2afa118c9dea07d01c5e1a29555824582e92f6ee8607591d1a7178acf29";
    };
    operandImages.prometheus-config-reloader = kix.options.image {
      repository = "quay.io/prometheus-operator/prometheus-config-reloader";
      tag = release;
      tagText = "config.image.tag";
      digest = "sha256:cc74ddedad4ab1c49446971f6d51302ad4303d8660a2018af925c7f62c114304";
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
          requires = [
            self.operatorServiceAccount
          ]
          ++ builtins.filter (p: p != null) [
            self.operatorService
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
            version = kix.image.version config.image;
            extraImages = [ (kix.image.ref config.operandImages.prometheus-config-reloader) ];
          };
        };
      }
    )
  ];
}
