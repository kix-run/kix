# Tests for the metricsApi role and the metrics-server package: the scope
# validators refuse a HorizontalPodAutoscaler on resource metrics, and the
# descheduler's KubernetesMetrics source, when the cluster binds the role
# absent and no instance provides it; a binding or a metrics-server instance
# satisfies them; and the package's own refusals.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  ...
}:

let
  metricsServerPackage = import ../../../packages/metrics-server;
  deschedulerPackage = import ../../../packages/descheduler;
  kindFlavor = import ../../flavors/kind.nix;
  rke2Flavor = import ../../flavors/rke2.nix;

  # A Deployment and an HPA over it. `hpa` is merged over an autoscaling/v2
  # HPA with no `metrics`.
  hpaPackage =
    hpa:
    { scope, ... }:
    {
      meta = {
        version = "test";
        description = "Deployment with a HorizontalPodAutoscaler";
        owner = "app-team";
      };
      build =
        { self, ... }:
        {
          deployment = scope.mkDeployment {
            name = "app";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                (
                  containerBase
                  // {
                    name = "app";
                    image = "registry.example/app:1.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
                  }
                )
              ];
            };
          };
          hpa = scope.mkResource (
            lib.recursiveUpdate {
              apiVersion = "autoscaling/v2";
              kind = "HorizontalPodAutoscaler";
              name = "app";
              spec = {
                scaleTargetRef = {
                  apiVersion = "apps/v1";
                  kind = "Deployment";
                  name = self.deployment.out.name;
                };
                maxReplicas = 3;
              };
            } hpa
          );
          root = {
            resource = self.deployment;
            requires = [ self.hpa ];
          };
        };
    };

  cpuMetric = {
    type = "Resource";
    resource = {
      name = "cpu";
      target = {
        type = "Utilization";
        averageUtilization = 80;
      };
    };
  };

  podsMetric = {
    type = "Pods";
    pods = {
      metric.name = "requests_per_second";
      target = {
        type = "AverageValue";
        averageValue = "10";
      };
    };
  };

  # A kind cluster (metricsApi bound absent) with instances in `instances`
  # and `module` merged over it.
  kindCluster =
    {
      instances ? { },
      module ? { },
      flavor ? kindFlavor,
    }:
    mkCluster [
      flavor
      { inherit instances; }
      module
    ];

  withMetricsServer = {
    metrics-server.metrics-server.package = metricsServerPackage;
  };

  hpaCluster =
    {
      hpa,
      provider ? false,
      module ? { },
    }:
    kindCluster {
      instances = {
        app.app.package = hpaPackage hpa;
      }
      // lib.optionalAttrs provider withMetricsServer;
      inherit module;
    };

  deschedulerCluster =
    {
      policy,
      provider ? false,
    }:
    kindCluster {
      instances = {
        descheduler.descheduler = {
          package = deschedulerPackage;
          config.policy = policy;
        };
      }
      // lib.optionalAttrs provider withMetricsServer;
    };

  kubernetesMetrics = {
    metricsProviders = [ { source = "KubernetesMetrics"; } ];
    profiles.default.pluginConfig.LowNodeUtilization.metricsUtilization.source = "KubernetesMetrics";
  };

  builds = cluster: !(evalFails cluster);

  # Each case is a cluster and whether it must evaluate.
  check =
    label: cases:
    let
      wrong = lib.attrNames (lib.filterAttrs (_: c: builds c.cluster != c.builds) cases);
    in
    wrong == [ ] || throw "${label}: these cases did not behave: ${toString wrong}";
in
{
  # Every HPA shape that reads metrics.k8s.io is refused with the role
  # absent and builds once a metrics-server instance claims the role.
  metrics-api-hpa-resource-metrics = check "HPA on resource metrics" {
    resource-absent = {
      cluster = hpaCluster { hpa.spec.metrics = [ cpuMetric ]; };
      builds = false;
    };
    resource-provided = {
      cluster = hpaCluster {
        hpa.spec.metrics = [ cpuMetric ];
        provider = true;
      };
      builds = true;
    };
    container-resource-absent = {
      cluster = hpaCluster {
        hpa.spec.metrics = [
          {
            type = "ContainerResource";
            containerResource = cpuMetric.resource // {
              container = "app";
            };
          }
        ];
      };
      builds = false;
    };
    default-metrics-absent = {
      cluster = hpaCluster { hpa = { }; };
      builds = false;
    };
    v1-absent = {
      cluster = hpaCluster {
        hpa = {
          apiVersion = "autoscaling/v1";
          spec.targetCPUUtilizationPercentage = 80;
        };
      };
      builds = false;
    };
    v1-provided = {
      cluster = hpaCluster {
        hpa = {
          apiVersion = "autoscaling/v1";
          spec.targetCPUUtilizationPercentage = 80;
        };
        provider = true;
      };
      builds = true;
    };
  };

  # An HPA on custom metrics only does not read metrics.k8s.io.
  metrics-api-hpa-custom-metrics-unchecked =
    builds (hpaCluster { hpa.spec.metrics = [ podsMetric ]; })
    || throw "an HPA on Pods metrics was refused with the metricsApi role absent";

  # A binding that says the environment serves the API satisfies the check
  # with no instance, and an unknown binding only warns.
  metrics-api-hpa-binding = check "HPA with a metricsApi binding" {
    exclusive = {
      cluster = hpaCluster {
        hpa.spec.metrics = [ cpuMetric ];
        module.cluster.roles.metricsApi.binding = lib.mkForce "exclusive";
      };
      builds = true;
    };
    unknown = {
      cluster = hpaCluster {
        hpa.spec.metrics = [ cpuMetric ];
        module.cluster.roles.metricsApi.binding = lib.mkForce null;
      };
      builds = true;
    };
  };

  # The descheduler reads metrics.k8s.io only with a KubernetesMetrics
  # provider in its policy.
  metrics-api-descheduler-kubernetes-metrics = check "descheduler KubernetesMetrics" {
    absent = {
      cluster = deschedulerCluster { policy = kubernetesMetrics; };
      builds = false;
    };
    provided = {
      cluster = deschedulerCluster {
        policy = kubernetesMetrics;
        provider = true;
      };
      builds = true;
    };
    no-provider-in-policy = {
      cluster = deschedulerCluster { policy = { }; };
      builds = true;
    };
  };

  # rke2 binds the role exclusive, so a managed metrics-server is refused;
  # with the binding absent the same instance builds.
  metrics-api-exclusive-refuses-managed = check "metrics-server under an exclusive binding" {
    rke2 = {
      cluster = kindCluster {
        flavor = rke2Flavor;
        instances = withMetricsServer;
      };
      builds = false;
    };
    rke2-absent = {
      cluster = kindCluster {
        flavor = rke2Flavor;
        instances = withMetricsServer;
        module.cluster.roles.metricsApi.binding = lib.mkForce "absent";
      };
      builds = true;
    };
  };

  # One per cluster: a second instance in another namespace is refused.
  metrics-api-second-instance = check "two metrics-server instances" {
    one = {
      cluster = kindCluster { instances = withMetricsServer; };
      builds = true;
    };
    two = {
      cluster = kindCluster {
        instances = withMetricsServer // {
          other.metrics-server.package = metricsServerPackage;
        };
      };
      builds = false;
    };
  };

  # extraArgs may not set the secure port, kubelet port, certificate
  # directory, or bind address; other flags pass through.
  metrics-api-owned-flags = check "metrics-server extraArgs" {
    secure-port = {
      cluster = kindCluster {
        instances.metrics-server.metrics-server = {
          package = metricsServerPackage;
          config.extraArgs = [ "--secure-port=4443" ];
        };
      };
      builds = false;
    };
    kubelet-port = {
      cluster = kindCluster {
        instances.metrics-server.metrics-server = {
          package = metricsServerPackage;
          config.extraArgs = [ "--kubelet-port=10255" ];
        };
      };
      builds = false;
    };
    cert-dir = {
      cluster = kindCluster {
        instances.metrics-server.metrics-server = {
          package = metricsServerPackage;
          config.extraArgs = [ "--cert-dir=/certs" ];
        };
      };
      builds = false;
    };
    bind-address = {
      cluster = kindCluster {
        instances.metrics-server.metrics-server = {
          package = metricsServerPackage;
          config.extraArgs = [ "--bind-address=127.0.0.1" ];
        };
      };
      builds = false;
    };
    insecure-tls = {
      cluster = kindCluster {
        instances.metrics-server.metrics-server = {
          package = metricsServerPackage;
          config.extraArgs = [ "--kubelet-insecure-tls" ];
        };
      };
      builds = true;
    };
  };

  # The APIService names the instance's Service, and the auth-reader
  # RoleBinding lands in kube-system.
  metrics-api-apiservice-wiring =
    let
      ms = manifests (kindCluster { instances = withMetricsServer; });
      apiService = byName "v1beta1.metrics.k8s.io" (ofKind "APIService" ms);
      authReader = byName "metrics-server-metrics-server-auth-reader" (ofKind "RoleBinding" ms);
    in
    (
      apiService.spec.service == {
        name = "metrics-server";
        namespace = "metrics-server";
      }
      && authReader.metadata.namespace == "kube-system"
    )
    || throw "metrics-server wiring: APIService service ${builtins.toJSON apiService.spec.service}, auth reader in ${authReader.metadata.namespace or "?"}";
}
