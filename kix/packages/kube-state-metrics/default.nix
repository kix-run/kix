# kube-state-metrics — Kubernetes object state metrics exporter.
#
# Single Deployment that listens to the K8s API server and exposes
# metrics about the state of objects (pods, deployments, nodes, etc.).
# Ships its own ServiceMonitor via optional prometheus DI.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
in
{
  meta = {
    version = "v2.15.0";
    description = "kube-state-metrics — Kubernetes object state exporter";
    defaultAliases = [ "kubeStateMetrics" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "registry.k8s.io/kube-state-metrics/kube-state-metrics";
        tag = "v2.15.0";
        pullPolicy = "IfNotPresent";
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
          memory = "64Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      };
    };
    metrics = kix.options.monitor;
  };

  build =
    {
      self,
      config,
      prometheus ? null,
      ...
    }:
    let
      hasMetrics = config.metrics.enabled && prometheus != null;
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

      inherit (scope.rbac)
        group
        core
        grant
        watch
        allow
        mkClusterRoleSet
        ;

      apps = group "apps" [
        "statefulsets"
        "deployments"
        "replicasets"
        "daemonsets"
      ];
      batch = group "batch" [
        "jobs"
        "cronjobs"
      ];
      autoscaling = group "autoscaling" [ "horizontalpodautoscalers" ];
      policy = group "policy" [ "poddisruptionbudgets" ];
      certs = group "certificates.k8s.io" [ "certificatesigningrequests" ];
      storage = group "storage.k8s.io" [
        "storageclasses"
        "volumeattachments"
      ];
      admReg = group "admissionregistration.k8s.io" [
        "mutatingwebhookconfigurations"
        "validatingwebhookconfigurations"
      ];
      net = group "networking.k8s.io" [
        "networkpolicies"
        "ingresses"
        "ingressclasses"
      ];
      coord = group "coordination.k8s.io" [ "leases" ];
      rbacGroup = group "rbac.authorization.k8s.io" [
        "clusterroles"
        "clusterrolebindings"
        "roles"
        "rolebindings"
      ];

      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        labels = scope.selectorLabels;
        roles = {
          "${name}" = grant [
            (core.configmaps |> watch)
            (core.secrets |> watch)
            (core.nodes |> watch)
            (core.pods |> watch)
            (core.services |> watch)
            (core "resourcequotas" |> watch)
            (core "replicationcontrollers" |> watch)
            (core "limitranges" |> watch)
            (core.persistentvolumeclaims |> watch)
            (core.persistentvolumes |> watch)
            (core.namespaces |> watch)
            (core.endpoints |> watch)
            (core.serviceaccounts |> watch)
            (apps.statefulsets |> watch)
            (apps.deployments |> watch)
            (apps.replicasets |> watch)
            (apps.daemonsets |> watch)
            (batch.jobs |> watch)
            (batch.cronjobs |> watch)
            (autoscaling.horizontalpodautoscalers |> watch)
            (policy.poddisruptionbudgets |> watch)
            (certs.certificatesigningrequests |> watch)
            (storage.storageclasses |> watch)
            (storage.volumeattachments |> watch)
            (admReg.mutatingwebhookconfigurations |> watch)
            (admReg.validatingwebhookconfigurations |> watch)
            (net.networkpolicies |> watch)
            (net.ingresses |> watch)
            (net.ingressclasses |> watch)
            (coord.leases |> watch)
            (rbacGroup.clusterroles |> watch)
            (rbacGroup.clusterrolebindings |> watch)
            (rbacGroup.roles |> watch)
            (rbacGroup.rolebindings |> watch)
          ];
        };
      };

    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                fsGroup = 65534;
              };
              containers = [
                {
                  name = "kube-state-metrics";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "--port=8080"
                    "--telemetry-port=8081"
                  ];
                  ports = [
                    (kix.port "http-metrics" 8080)
                    (kix.port "telemetry" 8081)
                  ];
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8080;
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                  };
                }
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
            };
          };
        }
        |> scope.mkDeployment;

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          type = "ClusterIP";
          ports = [
            {
              name = "http-metrics";
              port = 8080;
              targetPort = "http-metrics";
              protocol = "TCP";
            }
            {
              name = "telemetry";
              port = 8081;
              targetPort = "telemetry";
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      # ── Monitoring (optional via DI) ─────────────────────────────────────

      serviceMonitor =
        if hasMetrics then
          mkServiceMonitor {
            name = "${name}-monitor";
            spec = {
              selector.matchLabels = self.deployment.out.selector;
              endpoints = [
                {
                  port = "http-metrics";
                  interval = config.metrics.interval or "30s";
                  honorLabels = true;
                }
              ];
            };
          }
        else
          null;

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.deployment
        ]
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor;
      };
    }
    // clusterRoles;
}
