# kube-state-metrics: the exporter that turns the state of Kubernetes
# objects (pods, deployments, nodes, and more) into metrics.
#
# Installs a Deployment, its ServiceAccount, a ClusterRole that can list and
# watch the kinds it reports, and a Service on port 8080 (metrics) and 8081
# (its own telemetry). With a `prometheus` dependency and `metrics.enabled`,
# it also renders a ServiceMonitor through `prometheus.out.mkServiceMonitor`.
#
# Dependencies:
#   prometheus (optional)   the scraper whose ServiceMonitor builder it uses
#
# Minimal instance:
#
#   instances.monitoring.kube-state-metrics.package = packages.kube-state-metrics;
#
# `out`: the Service's `name`, `fqdn`, and `port`.
#
# Escape hatches: the instance's `partsOverlays`.
#
# Limits: one replica at every availability level (`availability.max =
# "none"`), because a second unsharded replica duplicates every series.

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
    version = "v2.19.1";
    description = "kube-state-metrics: Kubernetes object state exporter";
    owner = "platform";
    defaultAliases = [ "kubeStateMetrics" ];
    k8s.minVersion = "1.25";
    # One exporter: a second replica duplicates every series, and this
    # package does not wire `--shard`/`--total-shards`.
    availability.max = "none";
  };

  options = {
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Merged over the default kubernetes.io/os=linux selector.";
    };
    image = kix.options.image {
      repository = "registry.k8s.io/kube-state-metrics/kube-state-metrics";
      tag = "v2.19.1";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "1";
        memory = "256Mi";
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
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              # Kubernetes' default, set explicitly; the kube-state-metrics
              # chart (8.3.1) sets none.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                fsGroup = 65534;
              };
              containers = [
                {
                  name = "kube-state-metrics";
                  image = kix.image.ref config.image;
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
              }
              // config.nodeSelector;
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
              targetPort = 8080;
              protocol = "TCP";
            }
            {
              name = "telemetry";
              port = 8081;
              targetPort = 8081;
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
              # A ServiceMonitor selects Services, not pods.
              selector.matchLabels = self.service.out.selector;
              endpoints = [
                (
                  {
                    port = "http-metrics";
                    honorLabels = true;
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) {
                    inherit (config.metrics) interval;
                  }
                )
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
