# clusters/test-keda.nix: KEDA scaling a workload from Prometheus and from
# NATS JetStream, under Cilium default deny.
#
# `keda` runs the operator, the metrics API server, and the admission
# webhooks, with metrics on (prometheus-operator and a Prometheus server in
# `monitoring`). In `app`, a NATS server with JetStream, a Job that creates
# the stream `events` and its pull consumer `worker`, and a Deployment
# `worker` with no `spec.replicas`, scaled by one ScaledObject with two
# triggers:
#   - prometheus: the query `vector(3)` with threshold 1, so the trigger
#     alone asks for 3 replicas;
#   - nats-jetstream: the consumer's pending messages with lagThreshold 5,
#     read from the NATS monitoring endpoint (port 8222).
# The trigger addresses come from the Services' `out`, so Kix derives the
# operator's egress to Prometheus on 9090 and to the NATS monitoring Service
# on 8222, and their ingress from the operator. The metrics API server's
# egress to the operator's gRPC port comes from the address the package
# passes it.
#
# A live test should see, in order:
#   1. The deploy finish, which waits for APIService
#      v1beta1.external.metrics.k8s.io to report Available, so the API server
#      reaches the metrics API server and trusts the CA the operator wrote.
#   2. ScaledObject app/worker Ready=True, and the Deployment at 3 replicas.
#   3. `kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/app/s0-prometheus?labelSelector=scaledobject.keda.sh%2Fname%3Dworker"`
#      return the value 3.
#   4. After 20 messages are published to `events.test`, the Deployment reach
#      4 replicas (20 pending / lagThreshold 5) and go back to 3 once the
#      stream is purged. Publish from a nats-box pod (the image the streams
#      Job uses) with `nats --server nats://nats.app:4222 pub events.test hi
#      --count 20`. Under default deny that pod needs egress to nats on 4222:
#      run it from the streams Job's pod template, or add a platform intent.
#   5. No `forbidden` in the logs of the three components, and
#      `kubectl auth can-i` true for each rule of their roles, as their own
#      ServiceAccounts.
#
# Bring up: kind create cluster --name keda --kubeconfig /tmp/kc-keda \
#             --config <config>
#           where the config sets networking.disableDefaultCNI = true, so the
#           cilium instance enforces policy.
# Build:    nix run .#kix -- check keda
# Deploy:   KUBECONFIG=/tmp/kc-keda nix run .#kix -- deploy keda --context kind-keda -y

{ kix, packages }:

let
  # A NATS server with JetStream on an emptyDir, and a Job that creates the
  # stream and consumer the trigger reads. Test fixture only: one replica,
  # no authentication.
  natsPackage =
    { scope, kix, ... }:
    let
      name = scope.instanceName;
      labels = scope.selectorLabels // {
        "app.kubernetes.io/component" = "server";
      };
    in
    {
      meta = {
        description = "NATS server with JetStream for the KEDA test cluster";
        owner = "app-team";
      };

      options = {
        image = kix.options.image {
          repository = "docker.io/library/nats";
          tag = "2.15.3-alpine";
          digest = "sha256:558394a23dd3c36f2d3a64b51865fd09908010e80a542cea5e75c2af543ed62a";
        };
        boxImage = kix.options.image {
          repository = "docker.io/natsio/nats-box";
          tag = "0.20.2";
          digest = "sha256:5162fca0f56ebe6f78e612e1ded143ce978e088393476033020e6251358dba6f";
        };
      };

      build =
        { self, config, ... }:
        let
          container = {
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              readOnlyRootFilesystem = true;
            };
            resources = {
              requests = {
                cpu = "10m";
                memory = "32Mi";
              };
              limits = {
                cpu = "500m";
                memory = "256Mi";
              };
            };
          };
          podSecurity = {
            runAsNonRoot = true;
            runAsUser = 1000;
            runAsGroup = 1000;
            seccompProfile.type = "RuntimeDefault";
          };
        in
        {
          server = scope.mkDeployment {
            inherit name;
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  securityContext = podSecurity;
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    (
                      container
                      // {
                        name = "nats";
                        image = kix.image.ref config.image;
                        command = [ "nats-server" ];
                        args = [
                          "--jetstream"
                          "--store_dir=/data"
                          "--http_port=8222"
                        ];
                        ports = [
                          (kix.port "client" 4222)
                          (kix.port "monitor" 8222)
                        ];
                        livenessProbe.httpGet = {
                          path = "/healthz";
                          port = "monitor";
                        };
                        readinessProbe.httpGet = {
                          path = "/healthz";
                          port = "monitor";
                        };
                        volumeMounts = [
                          {
                            name = "data";
                            mountPath = "/data";
                          }
                        ];
                      }
                    )
                  ];
                  volumes = [
                    {
                      name = "data";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
          };

          # Clients connect here.
          service =
            self.server
            |> kix.service.fromWorkload {
              inherit name;
              labels."app.kubernetes.io/component" = "client";
              ports = [
                {
                  name = "client";
                  port = 4222;
                  targetPort = "client";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource;

          # The monitoring endpoint KEDA's nats-jetstream trigger reads, on a
          # Service of its own so the operator's derived egress covers 8222
          # only.
          monitorService =
            self.server
            |> kix.service.fromWorkload {
              name = "${name}-monitor";
              labels."app.kubernetes.io/component" = "monitor";
              ports = [
                {
                  name = "monitor";
                  port = 8222;
                  targetPort = "monitor";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource;

          # Create the stream and its pull consumer unless they exist, so a
          # rerun changes nothing.
          streams = scope.mkJob {
            name = "${name}-streams";
            spec = {
              backoffLimit = 6;
              template.metadata.labels = scope.selectorLabels // {
                "app.kubernetes.io/component" = "streams";
              };
              template.spec = {
                restartPolicy = "OnFailure";
                securityContext = podSecurity;
                containers = [
                  (
                    container
                    // {
                      name = "streams";
                      image = kix.image.ref config.boxImage;
                      # The image's working directory is /root, which the
                      # nats CLI cannot read as this pod's user.
                      workingDir = "/tmp";
                      command = [
                        "sh"
                        "-ec"
                        ''
                          nats stream info events >/dev/null 2>&1 \
                            || nats stream add events --subjects 'events.>' --defaults
                          nats consumer info events worker >/dev/null 2>&1 \
                            || nats consumer add events worker --pull --defaults
                        ''
                      ];
                      env = [
                        {
                          name = "NATS_URL";
                          value = "nats://${self.service.out.fqdn}:4222";
                        }
                        # The nats CLI keeps its contexts under $HOME.
                        {
                          name = "HOME";
                          value = "/tmp";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                    }
                  )
                ];
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
              };
            };
          };

          root = {
            resource = self.service;
            requires = [ self.streams ];
            out = {
              monitorEndpoint = "${self.monitorService.out.fqdn}:8222";
            };
          };
        };
    };

  # The scale target and its ScaledObject.
  workerPackage =
    { scope, kix, ... }:
    let
      name = scope.instanceName;
    in
    {
      meta = {
        description = "Worker scaled by KEDA from Prometheus and NATS JetStream";
        owner = "app-team";
      };

      options.image = kix.options.image {
        repository = "docker.io/nginxinc/nginx-unprivileged";
        tag = "1.27-alpine";
        digest = "sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0";
      };

      build =
        {
          self,
          config,
          keda,
          prometheus,
          nats,
          ...
        }:
        {
          # KEDA owns spec.replicas, so the Deployment leaves it out.
          worker = scope.mkDeployment {
            inherit name;
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 101;
                  seccompProfile.type = "RuntimeDefault";
                };
                terminationGracePeriodSeconds = 30;
                containers = [
                  {
                    name = "worker";
                    image = kix.image.ref config.image;
                    ports = [ (kix.port "http" 8080) ];
                    readinessProbe.tcpSocket.port = "http";
                    livenessProbe.tcpSocket.port = "http";
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits = {
                        cpu = "100m";
                        memory = "64Mi";
                      };
                    };
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                      readOnlyRootFilesystem = true;
                    };
                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
              };
            };
          };

          # region:kedaScaledObject
          scaler = scope.mkCR keda.out.crds.ScaledObject {
            name = "worker";
            spec = {
              scaleTargetRef.name = self.worker.out.name;
              minReplicaCount = 1;
              maxReplicaCount = 6;
              triggers = [
                {
                  type = "prometheus";
                  metadata = {
                    # The Service address orders this ScaledObject after
                    # Prometheus and opens the KEDA operator's egress to it.
                    serverAddress = prometheus.out.serviceUrl;
                    query = "vector(3)";
                    threshold = "1";
                  };
                }
                {
                  type = "nats-jetstream";
                  metadata = {
                    natsServerMonitoringEndpoint = nats.out.monitorEndpoint;
                    account = "$G";
                    stream = "events";
                    consumer = "worker";
                    lagThreshold = "5";
                  };
                }
              ];
            };
          };
          # endregion:kedaScaledObject

          root = {
            resource = self.worker;
            requires = [ self.scaler ];
          };
        };
    };
in
kix.buildCluster {
  name = "keda";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        cluster.availability.default = "none";
        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.monitoring = {
          prometheus-operator.package = packages.experimental.prometheus-operator;
          prometheus.package = packages.experimental.prometheus;
        };

        # region:kedaInstance
        instances.keda.keda.package = packages.experimental.keda;
        # endregion:kedaInstance

        instances.app = {
          nats.package = natsPackage;
          worker = {
            package = workerPackage;
            deps.prometheus = ref.monitoring.prometheus;
          };
        };
      }
    )
  ];
}
