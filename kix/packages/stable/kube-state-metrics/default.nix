# kube-state-metrics: the exporter that turns the state of Kubernetes
# objects (pods, deployments, nodes, and more) into metrics.
#
# Installs a Deployment, its ServiceAccount, a ClusterRole that can list and
# watch the kinds it reports, and a Service on port 8080 (metrics) and 8081
# (its own telemetry). With a `prometheus` dependency and `metrics.enabled`,
# it also renders a ServiceMonitor through `kix.monitor`.
#
# Dependencies:
#   prometheus (optional)   the scraper whose ServiceMonitor builder it uses
#
# Minimal instance:
#
#   instances.monitoring.kube-state-metrics.package = packages.kube-state-metrics;
#
# `out`: the Service's `name`, `fqdn`, and `port`, and `version`, the
# kube-state-metrics version `image.tag` names. The Service name is the
# `job` label of every series, which the kube-state-metrics rules of
# prometheus-default-rules read through its `kubeStateMetrics` dependency.
#
# Escape hatches: `extraArgs` for kube-state-metrics flags, and the
# instance's `partsOverlays`.
#
# Limits: one replica at every availability level (`availability.max =
# "none"` on the Deployment), because a second unsharded replica duplicates
# every series. The package ships no alerts; prometheus-default-rules does.

{
  scope,
  lib,
  kix,
}:
let
  release = "v2.19.1";
  name = scope.instanceName;
  who = "kube-state-metrics ${scope.namespaceName}/${name}";
  metricsPort = 8080;
  telemetryPort = 8081;
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "kube-state-metrics: Kubernetes object state exporter";
    owner = "platform";
    defaultAliases = [ "kubeStateMetrics" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/kube-state-metrics/kube-state-metrics";
      tag = release;
      digest = "sha256:85108987d044b18a098126732f98602df408888c0f7d456241f5abefb9744bc1";
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
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--metric-labels-allowlist=pods=[app.kubernetes.io/name]" ];
      description = "kube-state-metrics flags appended after the package's, such as `--resources` or `--metric-labels-allowlist`. `--port`, `--telemetry-port`, and the sharding flags are refused: the probes and the Service use the ports, and the package runs one unsharded replica.";
    };
    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        ...
      }:
      let
        args = [
          "--port=${toString metricsPort}"
          "--telemetry-port=${toString telemetryPort}"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--port" = "the probes and the Service use port ${toString metricsPort}; remove it.";
            "--telemetry-port" = "the Service uses port ${toString telemetryPort}; remove it.";
            "--shard" = "the package runs one unsharded replica; remove it.";
            "--total-shards" = "the package runs one unsharded replica; remove it.";
          };
        } config.extraArgs;

        probe = {
          httpGet = {
            path = "/healthz";
            port = "http-metrics";
          };
          initialDelaySeconds = 5;
          periodSeconds = 10;
        };

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
        discovery = group "discovery.k8s.io" [ "endpointslices" ];
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

        # Upstream's examples/standard/cluster-role.yaml without tokenreviews
        # and subjectaccessreviews, which only `--auth-filter` uses.
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
              (discovery.endpointslices |> watch)
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
        };

        deployment = scope.mkDeployment {
          inherit name;
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              # Kubernetes' default; kube-state-metrics holds no state to drain.
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
                  inherit args;
                  ports = [
                    (kix.port "http-metrics" metricsPort)
                    (kix.port "telemetry" telemetryPort)
                  ];
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  livenessProbe = probe;
                  readinessProbe = probe;
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            };
          };
        };

        service =
          self.deployment
          |> kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http-metrics";
                port = metricsPort;
                targetPort = "http-metrics";
                protocol = "TCP";
              }
              {
                name = "telemetry";
                port = telemetryPort;
                targetPort = "telemetry";
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          out.version = kix.image.version config.image;
          requires = [
            self.serviceAccount
            self.deployment
          ];
        };
      }
      // clusterRoles
    )

    # The series carry the `namespace` and `pod` of the objects they
    # describe. Without honorLabels, Prometheus renames them to
    # `exported_namespace` and `exported_pod`.
    (kix.monitor {
      service = "service";
      port = "http-metrics";
      honorLabels = true;
    })
  ];
}
