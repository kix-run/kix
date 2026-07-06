# prometheus-operator — Kubernetes operator for Prometheus monitoring stack.
#
# Manages monitoring.coreos.com CRDs: Prometheus, Alertmanager, ServiceMonitor,
# PodMonitor, PrometheusRule, Probe, ScrapeConfig, ThanosRuler, AlertmanagerConfig.
#
# Exposes CRD builder functions via `out`:
#   out.mkServiceMonitor  — create ServiceMonitor CRs
#   out.mkPodMonitor      — create PodMonitor CRs
#   out.mkPrometheusRule  — create PrometheusRule CRs
#   out.mkPrometheus      — create Prometheus CRs (used by packages/prometheus)
#   out.mkAlertmanager    — create Alertmanager CRs (used by packages/alertmanager)
#   out.mkProbe           — create Probe CRs
#
# This replaces the `partsOverlays` CRDRef hack in cluster monitoring configs.

{
  scope,
  lib,
}:

{
  meta = {
    version = "v0.82.0";
    description = "Prometheus Operator — monitoring.coreos.com CRD controller";
    defaultAliases = [
      "prometheus"
      "prometheusOperator"
    ];
    k8s.minVersion = "1.25";
    # This package owns the operator.prometheus.io annotation domain (it
    # stamps its CRDs with it); declared for the
    # architecture.annotationDomainOwnership lint (v2_discussions/128).
    annotationDomains = [ "operator.prometheus.io" ];
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus-operator/prometheus-operator";
        tag = "v0.82.0";
        pullPolicy = "IfNotPresent";
      };
    };
    prometheusConfigReloader = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/prometheus-operator/prometheus-config-reloader";
          tag = "v0.82.0";
        };
      };
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };
    controllerGenVersion = lib.mkOption {
      type = lib.types.str;
      default = "v0.17.2";
      description = ''
        controller-gen version stamped onto each CRD via the
        `controller-gen.kubebuilder.io/version` annotation. Mirrors the
        chart-rendered annotation; bump to match upstream releases.
      '';
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
    hostNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "When true, also forces dnsPolicy=ClusterFirstWithHostNet.";
    };
    denyNamespaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "If non-empty, appends --deny-namespaces=<comma-list> to args.";
    };
    namespaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "If non-empty, appends --namespaces=<comma-list> to args.";
    };
    imagePullSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    serviceAccountAnnotations = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    extraVolumeMounts = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
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

    # ── kubelet Service indirection ───────────────────────────────────────
    # Mirrors chart's `kubeletService` block. The `--kubelet-service=<ns>/
    # <name>` flag tells the operator which Service exposes kubelet metrics
    # so it can stamp the right targets on Prometheus CRs. Default matches
    # chart: `kube-system/<release>-kubelet`. Disabling drops the flag.
    kubeletService = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          namespace = lib.mkOption {
            type = lib.types.str;
            default = "kube-system";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "kubelet";
          };
        };
      };
      default = { };
    };

    # ── Probe tunables ────────────────────────────────────────────────────
    # Mirrors chart's `prometheusOperator.{liveness,readiness}Probe`.
    # `enabled` toggles the probe entirely; the other fields override the
    # chart-equivalent defaults that kix used to hardcode.
    livenessProbe = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          initialDelaySeconds = lib.mkOption {
            type = lib.types.int;
            default = 15;
          };
          periodSeconds = lib.mkOption {
            type = lib.types.int;
            default = 10;
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          failureThreshold = lib.mkOption {
            type = lib.types.int;
            default = 3;
          };
          successThreshold = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
        };
      };
      default = { };
    };
    readinessProbe = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          initialDelaySeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          periodSeconds = lib.mkOption {
            type = lib.types.int;
            default = 5;
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          failureThreshold = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          successThreshold = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
        };
      };
      default = { };
    };

    # ── Pod-level extras ─────────────────────────────────────────────────
    # Mirrors chart's `prometheusOperator.{lifecycle, dnsConfig}`. Both
    # take free-form attrsets; null = field omitted. Chart references at
    # `templates/prometheus-operator/deployment.yaml:153` (lifecycle) and
    # `:217` (dnsConfig).
    lifecycle = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = "Container lifecycle hooks (preStop/postStart). null = omitted.";
    };
    dnsConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = "Pod-level DNS config (nameservers, searches, options). null = omitted.";
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
        ...
      }:
      {
        root = {
          resource = self.operatorDeployment;
          requires =
            # CRDs (deployed in early waves before operator starts)
            [
              self.crds.serviceMonitors
              self.crds.podMonitors
              self.crds.prometheusRules
              self.crds.probes
              self.crds.prometheuses
              self.crds.alertmanagers
              self.crds.alertmanagerConfigs
              self.crds.prometheusAgents
              self.crds.scrapeConfigs
              self.crds.thanosRulers
            ]
            # Operator resources
            ++ [
              self.operatorServiceAccount
              self.operatorService
            ];

          # Expose CRD builders — packages depend on these via DI
          # Usage: prometheus.out.mkServiceMonitor scope { ... }
          out = {
            inherit (self.crds.serviceMonitors.out) mkCR;
            mkServiceMonitor = self.crds.serviceMonitors.out.mkCR;
            mkPodMonitor = self.crds.podMonitors.out.mkCR;
            mkPrometheusRule = self.crds.prometheusRules.out.mkCR;
            mkProbe = self.crds.probes.out.mkCR;
            mkPrometheus = self.crds.prometheuses.out.mkCR;
            mkAlertmanager = self.crds.alertmanagers.out.mkCR;
            # The operator injects a config-reloader sidecar into Prometheus
            # and Alertmanager pods — not in any kix-generated manifest.
            extraImages = [
              "${config.prometheusConfigReloader.image.repository}:${config.prometheusConfigReloader.image.tag}"
            ];
          };
        };
      }
    )
  ];
}
