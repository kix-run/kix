# clusters/test-rabbitmq.nix: the RabbitMQ packages under Cilium
# default-deny, with every option the packages read turned on.
#
# rabbitmq-operator runs in rabbitmq-system with metrics (a ServiceMonitor
# through prometheus-operator), and cert-manager issues its webhook
# certificate. No Prometheus server runs, so the scrape paths to the
# operator and to the RabbitMQ pods are not derived here: prometheus-operator
# and a prometheus instance both answer the `prometheus` alias, and every
# monitoring package would need its dependency named. In `messaging`, `rabbitmq` is a one-node
# rabbitmq-cluster with a settings entry, a default vhost, and an extraSpec
# plugin. `rabbitmq-ha` runs three nodes, which turns on the derived spread
# and the PodDisruptionBudget. Both have a PodMonitor, since `metrics` is on
# by default. `perf-test` stands in for an
# AMQP consumer: it reads `rabbitmq` through `deps.rabbitmq`, which under
# default deny gives it egress to the RabbitMQ pods on TCP 5672, and
# publishes and consumes one message a second on the default vhost with the
# default user's credentials.
#
# Build:  nix build .#cluster-rabbitmq --extra-experimental-features pipe-operators
# Deploy: kix deploy rabbitmq --flake ./clusters --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

let
  # A stand-in AMQP client: RabbitMQ's PerfTest load generator at one
  # message a second.
  perfTestPackage = {
    meta = {
      description = "RabbitMQ PerfTest as a stand-in AMQP consumer";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        kix,
        rabbitmq,
        ...
      }:
      let
        labels = scope.selectorLabels;
      in
      {
        deployment = scope.mkDeployment {
          name = scope.instanceName;
          spec = {
            replicas = 1;
            selector.matchLabels = labels;
            template = {
              metadata.labels = labels;
              spec = {
                # The Kubernetes default; PerfTest needs no longer to stop.
                terminationGracePeriodSeconds = 30;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65532;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  {
                    name = "perf-test";
                    image = "docker.io/pivotalrabbitmq/perf-test:2.25.0@sha256:b803911d60fdf6885fc6313f0d56a0c2c743bfdd27ac118f5e4b320c36c7b8c9";
                    env = kix.mkEnvVars {
                      AMQP_HOST = rabbitmq.out.host;
                      AMQP_PORT = rabbitmq.out.port;
                      AMQP_VHOST = rabbitmq.out.vhost;
                      AMQP_USERNAME = rabbitmq.out.credentials.out.keyRef "username";
                      AMQP_PASSWORD = rabbitmq.out.credentials.out.keyRef "password";
                    };
                    # The kubelet expands $(VAR) from the env above. The
                    # password shows in the process arguments, which is
                    # acceptable for this test client only.
                    args = [
                      "--uri"
                      "amqp://$(AMQP_USERNAME):$(AMQP_PASSWORD)@$(AMQP_HOST):$(AMQP_PORT)/$(AMQP_VHOST)"
                      "--producers"
                      "1"
                      "--consumers"
                      "1"
                      "--rate"
                      "1"
                      # Serves /metrics on port 8080, which the probes read.
                      "--metrics-prometheus"
                    ];
                    ports = [ (kix.port "metrics" 8080) ];
                    livenessProbe.httpGet = {
                      path = "/metrics";
                      port = 8080;
                    };
                    readinessProbe.httpGet = {
                      path = "/metrics";
                      port = 8080;
                    };
                    resources = {
                      requests = {
                        cpu = "50m";
                        memory = "256Mi";
                      };
                      limits = {
                        cpu = "500m";
                        memory = "256Mi";
                      };
                    };
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                      readOnlyRootFilesystem = true;
                    };
                  }
                ];
              };
            };
          };
        };
        root = self.deployment;
      };
  };
in
kix.buildCluster {
  name = "test-rabbitmq";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.cilium;
        instances.monitoring.prometheus-operator.package = packages.prometheus-operator;
        instances.cert-manager.cert-manager.package = packages.cert-manager;
        instances.rabbitmq-system.rabbitmq-operator = {
          package = packages.rabbitmq-operator;
          config.metrics.enabled = true;
        };

        instances.messaging = {
          rabbitmq = {
            package = packages.rabbitmq-cluster;
            config = {
              storage.size = "1Gi";
              resources = {
                requests = {
                  cpu = "250m";
                  memory = "512Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "512Mi";
                };
              };
              metrics.enabled = true;
              settings = {
                default_vhost = "app";
                "vm_memory_high_watermark.relative" = "0.6";
              };
              extraSpec.rabbitmq.additionalPlugins = [ "rabbitmq_shovel" ];
            };
          };
          rabbitmq-ha = {
            package = packages.rabbitmq-cluster;
            config = {
              replicas = 3;
              storage.size = "1Gi";
              resources = {
                requests = {
                  cpu = "250m";
                  memory = "512Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "512Mi";
                };
              };
            };
          };
          perf-test = {
            package = perfTestPackage;
            deps.rabbitmq = ref.messaging.rabbitmq;
          };
        };
      }
    )
  ];
}
