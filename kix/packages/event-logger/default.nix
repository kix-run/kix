# Event Logger package: watches K8s events and logs them as JSON.
#
# Runs a Python script (via uv) that streams all cluster events to
# stdout in structured JSON format for log aggregation pipelines.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            ConfigMap (Python script), Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  commonLabels = {
    app = "event-logger";
  };

  metaLabels = commonLabels // {
    role = "monitoring";
  };

in
{
  meta = {
    version = "1.0.0";
    description = "A watcher that streams every cluster event to stdout as JSON for log pipelines";
    owner = "platform";
    # The watcher has no coordination between replicas, so one replica is
    # the ceiling it can honour.
    availability.max = "pod";
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/astral-sh/uv";
      tag = "python3.12-bookworm-slim";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Fixed at 1: a second watcher would log every cluster event twice.
      # See meta.availability.max.
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
          cpu = "1";
          memory = "512Mi";
        };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      # --- RBAC ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "event-logger";
        labels = metaLabels;
      };

      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "event-logger";
        labels = metaLabels;
        extra.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
        ];
      };

      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "event-logger";
        labels = metaLabels;
        extra.roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.out.name;
        };
        extra.subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
      };

      # --- ConfigMap (Python script) ---
      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "event-logger";
        labels = metaLabels;
        data."k8s_event_logger.py" = ''
          #!/usr/bin/env -S uv --quiet run --script
          # /// script
          # requires-python = ">=3.12"
          # dependencies = [
          #     "kubernetes>=29.0.0",
          #     "PyYAML>=5.3.1",
          # ]
          # ///
          import json
          import sys
          from datetime import datetime, timezone
          from typing import Any, Dict
          from kubernetes import client, config, watch
          class DateTimeEncoder(json.JSONEncoder):
              """Custom JSON encoder that can handle datetime objects."""
              def default(self, obj):
                  if isinstance(obj, datetime):
                      return obj.isoformat()
                  return super().default(obj)
          def format_event(event: Dict[str, Any]) -> Dict[str, Any]:
              """Format Kubernetes event for structured logging."""
              obj = event["object"]
              # Extract and format relevant fields
              formatted_event = {
                  "timestamp": datetime.now(timezone.utc).isoformat(),
                  "type": obj.type,
                  "reason": obj.reason,
                  "message": obj.message,
                  "count": obj.count,
                  "namespace": obj.metadata.namespace,
                  "name": obj.metadata.name,
                  "uid": obj.metadata.uid,
                  "involved_object_kind": obj.involved_object.kind,
                  "involved_object_name": obj.involved_object.name,
                  "involved_object_namespace": obj.involved_object.namespace,
                  "involved_object_uid": obj.involved_object.uid,
                  "involved_object_api_version": getattr(obj.involved_object, "api_version", None),
                  "first_timestamp": obj.first_timestamp,
                  "last_timestamp": obj.last_timestamp,
                  "event_time": getattr(obj, "event_time", None),
                  "reporting_component": getattr(obj, "reporting_component", None),
                  "source_component": getattr(obj.source, "component", None) if hasattr(obj, "source") else None,
              }
              # Clean None values for better JSON output
              return {k: v for k, v in formatted_event.items() if v is not None}
          def main():
              """Watch and log all Kubernetes events as JSON."""
              # Load kubeconfig based on whether we're running in-cluster or not
              try:
                  config.load_incluster_config()
                  print(
                      json.dumps({"message": "Using in-cluster configuration"}, cls=DateTimeEncoder),
                      flush=True,
                  )
              except config.ConfigException:
                  config.load_kube_config()
                  print(
                      json.dumps({"message": "Using kubeconfig file"}, cls=DateTimeEncoder),
                      flush=True,
                  )
              # Create API client
              v1 = client.CoreV1Api()
              w = watch.Watch()
              print(
                  json.dumps({"message": "Starting to watch Kubernetes events"}, cls=DateTimeEncoder),
                  flush=True,
              )
              # Watch events across all namespaces
              for event in w.stream(v1.list_event_for_all_namespaces):
                  formatted_event = format_event(event)
                  print(json.dumps(formatted_event, cls=DateTimeEncoder), flush=True)
          if __name__ == "__main__":
              main()
        '';
      };

      # --- Mounts ---
      scriptMount = kix.mount.configMap self.configMap {
        name = "config-volume";
        mountPath = "/app";
        defaultMode = 493; # 0755
      };

      # `uv run --script` resolves the script's dependencies into its cache
      # on every start, so the cache lives on a writable emptyDir.
      tmpMount = kix.mount.emptyDir {
        name = "tmp";
        mountPath = "/tmp";
      };

      # --- Deployment ---
      deployment =
        {
          name = "event-logger";
          labels = metaLabels;
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = commonLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Kubernetes default: the watcher holds no state to flush.
              terminationGracePeriodSeconds = 30;
              containers = [
                {
                  name = "event-logger";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/app/k8s_event_logger.py" ];
                  env = kix.mkEnvVars {
                    PYTHONUNBUFFERED = "1";
                    HOME = "/tmp";
                    UV_CACHE_DIR = "/tmp/uv-cache";
                  };
                  # The uv image defines no user of its own; uid 65532 is
                  # the conventional unprivileged `nonroot` id.
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 65532;
                    runAsGroup = 65532;
                    readOnlyRootFilesystem = true;
                    allowPrivilegeEscalation = false;
                  };
                  resources = config.resources;
                }
              ];
            };
          };
        }
        |> kix.withMounts [
          self.scriptMount
          self.tmpMount
        ]
        |> scope.mkDeployment;

      # --- Entry point ---
      root = self.deployment;
    };
}
