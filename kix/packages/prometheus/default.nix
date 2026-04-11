# prometheus — Prometheus server managed by the Prometheus Operator.
#
# Creates a Prometheus CR that the operator reconciles into a StatefulSet.
# Configurable retention, storage, resources, and scrape settings.
#
# DI deps:
#   prometheus-operator (required) — provides the Prometheus CRD
#
# Exposes:
#   out.serviceUrl — "http://<name>.<ns>.svc.cluster.local:9090"
#     for Grafana and other consumers

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "v3.1.0";
    description = "Prometheus time-series database";
    provides = [
      "tsdb"
      "metrics"
    ];
    defaultAliases = [
      "prometheusServer"
      "promServer"
    ];
    k8s.minVersion = "1.25";
    # Historical metrics are expendable — fresh start is acceptable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus/prometheus";
        tag = "v3.1.0";
      };
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    retention = lib.mkOption {
      type = lib.types.str;
      default = "7d";
    };
    retentionSize = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    evaluationInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "500m";
          memory = "2Gi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = null;
      description = "VolumeClaimTemplate spec for persistent storage. null = emptyDir.";
    };
    externalUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    # Selector scoping — by default, select all ServiceMonitors/PodMonitors/Rules
    # across all namespaces (matching the Helm chart's default behavior)
    serviceMonitorSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    podMonitorSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    ruleSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    serviceMonitorNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    podMonitorNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    ruleNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    securityContext = lib.mkOption {
      type = lib.types.anything;
      default = {
        runAsNonRoot = true;
        runAsUser = 1000;
        runAsGroup = 2000;
        fsGroup = 2000;
      };
    };
    alerting = lib.mkOption {
      type = lib.types.anything;
      default = null;
      description = "Alertmanager endpoints config. Set by cluster module.";
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheusOperator,
      ...
    }:
    let
      mkPrometheus = prometheusOperator.out.mkPrometheus;

      storageSpec =
        if config.storage != null then
          {
            volumeClaimTemplate = config.storage;
          }
        else
          null;

      inherit (scope.rbac)
        group
        core
        grant
        watch
        allow
        mkClusterRoleSet
        ;

      # Prometheus needs to scrape targets across all namespaces
      scrapeRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        labels = scope.selectorLabels;
        roles = {
          "${name}" = {
            rules =
              grant [
                (core.nodes |> watch)
                (core "nodes/metrics" |> allow [ "get" ])
                (core.services |> watch)
                (core.endpoints |> watch)
                (core.pods |> watch)
                (core.configmaps |> allow [ "get" ])
                (group "networking.k8s.io" [ "ingresses" ] |> (r: r.ingresses) |> watch)
              ]
              ++ [
                # nonResourceURLs for /metrics scraping
                {
                  nonResourceURLs = [
                    "/metrics"
                    "/metrics/cadvisor"
                  ];
                  verbs = [ "get" ];
                }
              ];
          };
        };
      };

    in
    {
      # ServiceAccount for the Prometheus pods
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # Prometheus CR — the operator reconciles this into a StatefulSet
      prometheus = mkPrometheus scope {
        name = name;
        spec = {
          replicas = config.replicas;
          image = "${config.image.repository}:${config.image.tag}";
          version = config.image.tag;
          serviceAccountName = self.serviceAccount.out.name;

          retention = config.retention;
          scrapeInterval = config.scrapeInterval;
          evaluationInterval = config.evaluationInterval;
          resources = config.resources;
          securityContext = config.securityContext;

          # Select all ServiceMonitors/PodMonitors/Rules across all namespaces
          serviceMonitorSelector = config.serviceMonitorSelector;
          podMonitorSelector = config.podMonitorSelector;
          ruleSelector = config.ruleSelector;
          serviceMonitorNamespaceSelector = config.serviceMonitorNamespaceSelector;
          podMonitorNamespaceSelector = config.podMonitorNamespaceSelector;
          ruleNamespaceSelector = config.ruleNamespaceSelector;

          enableAdminAPI = false;
          enableRemoteWriteReceiver = false;
        }
        // lib.optionalAttrs (storageSpec != null) { storage = storageSpec; }
        // lib.optionalAttrs (config.externalUrl != null) {
          externalUrl = config.externalUrl;
        }
        // lib.optionalAttrs (config.retentionSize != null) {
          retentionSize = config.retentionSize;
        }
        // lib.optionalAttrs (config.alerting != null) {
          alerting = config.alerting;
        }
        // lib.optionalAttrs (config.priorityClassName != null) {
          priorityClassName = config.priorityClassName;
        };
      };

      # Service for Prometheus (the operator creates one, but we define ours
      # for stable naming and DI-friendly out.serviceUrl)
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        spec = {
          type = "ClusterIP";
          # The operator labels the Prometheus pods with these labels
          selector = {
            "app.kubernetes.io/name" = "prometheus";
            "app.kubernetes.io/instance" = name;
          };
          ports = [
            {
              name = "http-web";
              port = 9090;
              targetPort = 9090;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          serviceUrl = "http://${name}.${ns}.svc.cluster.local:9090";
        };
      };

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.prometheus
        ];
        out = {
          inherit (self.service.out) serviceUrl;
          # The Prometheus CR's image is reconciled by the operator into a
          # StatefulSet — not directly in a kix-generated pod spec.
          extraImages = [
            "${config.image.repository}:${config.image.tag}"
          ];
        };
      };
    }
    // scrapeRoles;
}
