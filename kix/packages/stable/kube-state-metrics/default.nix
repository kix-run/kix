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
# Upgrades: kube-state-metrics keeps no data, so any version replaces any
# other, and going back is deploying the older package. From 2.20,
# `kube_pod_status_reason` has a series only for the reason a pod has, not a
# zero-valued series for every other reason.
#
# Kubernetes versions: when the cluster sets `k8sVersion`, the package
# leaves out the collectors whose API that version does not serve, and
# their kinds from the ClusterRole. Those are the MutatingAdmissionPolicy
# collectors before 1.36 and the ValidatingAdmissionPolicy collectors
# before 1.30. `--resources` in `extraArgs` replaces that choice.
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
  release = "v2.20.0";
  name = scope.instanceName;
  metricsPort = 8080;
  telemetryPort = 8081;
in
{
  meta = {
    version = release;
    description = "kube-state-metrics: Kubernetes object state exporter";
    owner = "platform";
    defaultAliases = [ "kubeStateMetrics" ];
    # Upstream states support for the Kubernetes version of the client-go
    # it builds with (README "Kubernetes Version" and data.yaml). On an
    # older cluster the package leaves out the collectors whose API that
    # cluster does not serve (`collectorsSince`), so nothing is known to
    # fail from 1.25. Move `supported` with `release`.
    k8s = {
      minVersion = "1.25";
      supported = {
        minVersion = "1.36";
        maxVersion = "1.36";
        source = "the compatibility matrix in kube-state-metrics' README";
      };
    };
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/kube-state-metrics/kube-state-metrics";
      tag = release;
      digest = "sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b";
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
        clusterConfig,
        ...
      }:
      let
        k8sVersion = clusterConfig.k8sVersion or null;

        # Name the first Kubernetes version that serves the API a collector
        # reads, for the collectors that read admissionregistration.k8s.io/v1
        # kinds newer than the package's minimum. Kubernetes 1.34 and 1.35
        # serve MutatingAdmissionPolicy as v1beta1 only.
        collectorsSince = {
          mutatingadmissionpolicies = "1.36";
          mutatingadmissionpolicybindings = "1.36";
          validatingadmissionpolicies = "1.30";
          validatingadmissionpolicybindings = "1.30";
        };
        # A cluster with no `k8sVersion` keeps every collector.
        served =
          collector:
          !(collectorsSince ? ${collector})
          || k8sVersion == null
          || kix.version.atLeast k8sVersion collectorsSince.${collector} != false;

        # Upstream's default collectors (DefaultResources in
        # pkg/options/resource.go). Move the list with `release`.
        defaultCollectors = [
          "certificatesigningrequests"
          "configmaps"
          "cronjobs"
          "daemonsets"
          "deployments"
          "endpointslices"
          "horizontalpodautoscalers"
          "ingresses"
          "jobs"
          "leases"
          "limitranges"
          "mutatingadmissionpolicies"
          "mutatingadmissionpolicybindings"
          "mutatingwebhookconfigurations"
          "namespaces"
          "networkpolicies"
          "nodes"
          "persistentvolumes"
          "persistentvolumeclaims"
          "poddisruptionbudgets"
          "pods"
          "replicasets"
          "replicationcontrollers"
          "resourcequotas"
          "secrets"
          "services"
          "statefulsets"
          "storageclasses"
          "validatingadmissionpolicies"
          "validatingadmissionpolicybindings"
          "validatingwebhookconfigurations"
          "volumeattachments"
        ];
        servedCollectors = builtins.filter served defaultCollectors;

        # kube-state-metrics parses flags with cobra and pflag
        # (pkg/options/options.go upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            {
              flags = [ "--port=${toString metricsPort}" ];
              reason = "the probes and the Service use port ${toString metricsPort}.";
            }
            {
              flags = [ "--telemetry-port=${toString telemetryPort}" ];
              reason = "the Service uses port ${toString telemetryPort}.";
            }
            # `--resources` in `extraArgs` replaces the package's choice.
            {
              defaults = lib.optional (
                servedCollectors != defaultCollectors
              ) "--resources=${lib.concatStringsSep "," servedCollectors}";
            }
            {
              names = [
                "--shard"
                "--total-shards"
              ];
              reason = "this package runs a single unsharded kube-state-metrics replica.";
            }
          ];
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
          "mutatingadmissionpolicies"
          "mutatingadmissionpolicybindings"
          "mutatingwebhookconfigurations"
          "validatingadmissionpolicies"
          "validatingadmissionpolicybindings"
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
            "${name}" = grant (
              [
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
              ]
              # Grant the admission policy kinds only where a collector reads
              # them.
              ++ map (collector: admReg.${collector} |> watch) (
                builtins.filter served (builtins.attrNames collectorsSince)
              )
              ++ [
                (admReg.validatingwebhookconfigurations |> watch)
                (net.networkpolicies |> watch)
                (net.ingresses |> watch)
                (net.ingressclasses |> watch)
                (coord.leases |> watch)
                (rbacGroup.clusterroles |> watch)
                (rbacGroup.clusterrolebindings |> watch)
                (rbacGroup.roles |> watch)
                (rbacGroup.rolebindings |> watch)
              ]
            );
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
