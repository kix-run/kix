# alertmanager — Alertmanager managed by the Prometheus Operator.
#
# Creates an Alertmanager CR that the operator reconciles into a StatefulSet.
# Routing config (receivers, routes) is cluster-specific.
#
# DI deps:
#   prometheus-operator (required) — provides the Alertmanager CRD
#
# Exposes:
#   out.serviceUrl — for Prometheus alerting config

{
  scope,
  lib,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "v0.28.1";
    description = "Alertmanager — alert routing and deduplication";
    provides = [ "alerting" ];
    defaultAliases = [ "alertmanager" ];
    k8s.minVersion = "1.25";
    # Silences and notification state are recoverable — expendable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus/alertmanager";
        tag = "v0.28.1";
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
          cpu = "10m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    # Alertmanager config — receivers, routes, etc.
    # This is cluster-specific and set in the cluster module.
    config = lib.mkOption {
      type = lib.types.anything;
      default = {
        global.resolve_timeout = "5m";
        route = {
          group_by = [
            "namespace"
            "alertname"
          ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
          receiver = "null";
          routes = [
            {
              receiver = "null";
              matchers = [ "alertname = Watchdog" ];
            }
          ];
        };
        receivers = [
          { name = "null"; }
        ];
      };
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = null;
    };
  };

  build =
    {
      self,
      config,
      prometheusOperator,
      ...
    }:
    let
      mkAlertmanager = prometheusOperator.out.mkAlertmanager;
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # Alertmanager config as a Secret (the operator expects this)
      alertmanagerConfig = scope.mkSecret {
        name = "alertmanager-${name}";
        stringData."alertmanager.yaml" = builtins.toJSON config.config;
      };

      # Alertmanager CR — operator reconciles into StatefulSet
      alertmanager = mkAlertmanager scope {
        inherit name;
        spec = {
          replicas = config.replicas;
          image = "${config.image.repository}:${config.image.tag}";
          version = config.image.tag;
          serviceAccountName = self.serviceAccount.out.name;
          resources = config.resources;
        }
        // lib.optionalAttrs (config.priorityClassName != null) {
          priorityClassName = config.priorityClassName;
        }
        // lib.optionalAttrs (config.storage != null) {
          storage.volumeClaimTemplate = config.storage;
        };
      };

      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        spec = {
          type = "ClusterIP";
          selector = {
            "app.kubernetes.io/name" = "alertmanager";
            "app.kubernetes.io/instance" = name;
          };
          ports = [
            {
              name = "http-web";
              port = 9093;
              targetPort = 9093;
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          serviceUrl = "http://${name}.${ns}.svc.cluster.local:9093";
        };
      };

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.alertmanagerConfig
          self.alertmanager
        ];
        out = {
          inherit (self.service.out) serviceUrl;
          # The Alertmanager CR's image is reconciled by the operator into a
          # StatefulSet — not directly in a kix-generated pod spec.
          extraImages = [
            "${config.image.repository}:${config.image.tag}"
          ];
        };
      };
    };
}
