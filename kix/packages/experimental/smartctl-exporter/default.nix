# Smartctl Exporter: SMART disk health metrics for Prometheus.
#
# Wraps the upstream prometheus-smartctl-exporter Helm chart.
# Deployed as a DaemonSet with privileged access to host /dev.
#
# Dependencies:
#   prometheus (optional)  a ServiceMonitor over the chart's Service, and
#                          alerts, while `metrics.enabled`.
#
# The chart's own ServiceMonitor and PrometheusRule stay off. They are
# prometheus-operator kinds, and a chart resource cannot depend on the
# package that declares them, so the cluster build refuses them (check 21).
# The package builds both through the prometheus dependency instead.
#
# Alerts: a PrometheusRule `<instance>-alerts` selects the chart Service's
# series. They rebuild the chart's rules with the metric names of the
# pinned exporter, one alert per device and pod:
#   SmartctlExporterDown (warning)       no exporter pod answers a scrape,
#                                        so no disk is watched.
#   SmartDeviceHealthFailed (critical)   the drive's own SMART health
#                                        assessment failed
#                                        (`smartctl_device_smart_status`).
#   SmartDeviceCriticalWarning (critical) an NVMe drive sets a critical
#                                        warning bit: spare below its
#                                        threshold, temperature, degraded
#                                        reliability, or read-only media.
#   SmartDeviceMediaErrors (warning)     an NVMe drive counted a new
#                                        unrecovered media error in the
#                                        last hour.
#   SmartDeviceTemperatureHigh (warning) the current temperature is above
#                                        `metrics.maxTemperature`.
# The chart's spare-threshold rule is left out, because the same condition
# sets a critical warning bit. Its interface-speed rule is left out: a
# drive on a slower port reports it for life, and nothing in the cluster
# can change it. One node's exporter down is left to
# prometheus-default-rules (TargetDown).
#
# Limits: the chart's Service renders whether or not metrics are scraped.
#
# Chart:   https://prometheus-community.github.io/helm-charts
# Name:    prometheus-smartctl-exporter
# Version: 0.16.0

{
  scope,
  lib,
  kix,
}:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://prometheus-community.github.io/helm-charts";
    name = "prometheus-smartctl-exporter";
    version = "0.16.0";
    hash = "sha256-YVZTmmCuNnRYeDDBLQNWib4+FBo4mjMCqM5EKyd/Gss=";
  };

  # The exporter release the chart's image runs. The chart has its own
  # version above.
  release = "v0.14.0";

  # The chart names its objects `<release>-<chart>` (_helpers.tpl).
  releaseName = "smartctl-exporter";
  serviceName = "${releaseName}-prometheus-smartctl-exporter";

  defaultValues = {
    image = {
      repository = "quay.io/prometheuscommunity/smartctl-exporter";
      # The chart renders `repository:tag` and has no digest value, so the
      # digest goes in the tag.
      tag = "${release}@sha256:cfe22c36d7d2fac48ebf619707305acb65eb0fb670656eb80f356e606d782bc1";
    };

    resources = {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "2";
        memory = "64Mi";
      };
    };

    tolerations = [
      {
        effect = "NoSchedule";
        operator = "Exists";
      }
    ];

    serviceMonitor.enabled = false;
    prometheusRules.enabled = false;
  };

  ns = scope.namespaceName;
  sel = ''namespace="${ns}",service="${serviceName}"'';
  # Every per-device description names the drive and the exporter pod,
  # which runs on the drive's node.
  device = "{{ $labels.device }} on the node of pod {{ $labels.pod }}";
in
{
  meta.version = lib.removePrefix "v" release;
  meta.description = "smartctl_exporter from the upstream Helm chart, a privileged DaemonSet that exports SMART disk health metrics to Prometheus";
  meta.owner = "platform";
  # smartctl reads SMART data from the node's block devices, which needs a
  # privileged container running as root.
  meta.unsafe = [
    "privileged"
    "run-as-root"
  ];

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  options.metrics = kix.options.monitor // {
    maxTemperature = lib.mkOption {
      type = lib.types.ints.positive;
      default = 70;
      description = "Drive temperature in degrees Celsius above which SmartDeviceTemperatureHigh fires. The default suits NVMe drives, which are often specified to 70 or more and run warm under load. Hard drives are often specified to 60, so lower it on nodes with only hard drives.";
    };
  };

  build = [
    (
      { config, scope, ... }:
      let
        resources = scope.helm.importChart {
          inherit chart scope releaseName;
          values = lib.recursiveUpdate defaultValues (config.values or { });
        };
      in
      resources.mkParts {
        root = builtins.head (resources.byKind "DaemonSet");
      }
    )

    # The lib passes a build function only the arguments it names, so the
    # wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        service = "service-${serviceName}";
        port = "http";
        alerts = {
          SmartctlExporterDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "No smartctl exporter answers.";
            description = "No pod of the smartctl exporter in ${ns} has answered a scrape for 10 minutes, so no disk's SMART health is watched. Check the DaemonSet in ${ns}.";
          };
          # 1 when smartctl reports `smart_status.passed`, 0 when the
          # drive's own assessment failed (smartctl.go upstream).
          SmartDeviceHealthFailed = {
            expr = "smartctl_device_smart_status{${sel}} == 0";
            "for" = "5m";
            severity = "critical";
            summary = "A disk failed its SMART health assessment.";
            description = "Disk ${device} reports that its SMART health assessment failed, so the drive expects to fail. Move data off it and replace it; `smartctl -a` on the node shows the failing attributes.";
          };
          SmartDeviceCriticalWarning = {
            expr = "smartctl_device_critical_warning{${sel}} != 0";
            "for" = "5m";
            severity = "critical";
            summary = "An NVMe disk reports a critical warning.";
            description = "NVMe disk ${device} reports critical warning bits {{ $value }}: 1 spare below threshold, 2 temperature, 4 reliability degraded, 8 read-only, 16 volatile memory backup failed. Read `smartctl -a` on the node and plan to replace the drive.";
          };
          # A lifetime count; the window spans the restart time, so the rule
          # needs no `for`.
          SmartDeviceMediaErrors = {
            expr = "increase(smartctl_device_media_errors{${sel}}[1h]) > 0";
            severity = "warning";
            summary = "An NVMe disk reports new media errors.";
            description = "NVMe disk ${device} counted new unrecovered media errors in the last hour, so some data on it could not be read back. Check the filesystem or volume above it, and watch whether the count keeps rising.";
          };
          SmartDeviceTemperatureHigh = {
            expr = ''smartctl_device_temperature{${sel},temperature_type="current"} > ${toString config.metrics.maxTemperature}'';
            "for" = "15m";
            severity = "warning";
            summary = "A disk runs hot.";
            description = "Disk ${device} has been at {{ $value }}°C for 15 minutes, above ${toString config.metrics.maxTemperature}°C. Heat shortens its life and can throttle it. Check the node's cooling and airflow.";
          };
        };
      } args
    )
  ];
}
