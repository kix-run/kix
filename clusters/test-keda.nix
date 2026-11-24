# clusters/test-keda.nix: KEDA scaling a workload from Prometheus and from
# NATS JetStream, with NATS in one namespace and the scaled workload in
# another, under Cilium default deny.
#
# `keda` runs the operator, the metrics API server, and the admission
# webhooks, with metrics on (prometheus-operator and a Prometheus server in
# `monitoring`). `messaging` runs packages.experimental.nats with three
# servers and JetStream, and requires a login from its `nats-auth` secret
# (test values only). In `app`, a Deployment `worker` with no
# `spec.replicas`, a Job that creates the stream `events` and its pull
# consumer `worker` on messaging/nats, and one ScaledObject with two
# triggers:
#   - prometheus: the query `vector(3)` with threshold 1, so the trigger
#     alone asks for 3 replicas;
#   - nats-jetstream: the consumer's pending messages with lagThreshold 5,
#     read from the NATS monitoring endpoint (port 8222) of messaging/nats.
#     The servers configure no accounts, so the stream is in the global
#     account `$G`.
# The worker names messaging/nats with `ref`. The Job logs in with
# `app/nats-login`, a copy of the login in its own namespace, because a
# Secret reference resolves only in the pod's namespace. The trigger
# addresses come from `out`, so Kix orders the ScaledObject after the
# Services and derives the operator's egress to Prometheus on 9090 and to
# the NATS servers on 8222 only, and their ingress from the operator. The
# Job's address gives it egress to the NATS servers on 4222. The metrics
# API server's egress to the operator's gRPC port comes from the address
# the package passes it.
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
#      stream is purged. Publish from a pod with the streams Job's pod labels
#      in `app`, which policy admits to messaging/nats on 4222, logging in
#      with app/nats-login.
#   5. No `forbidden` in the logs of the three components, and
#      `kubectl auth can-i` true for each rule of their roles, as their own
#      ServiceAccounts.
#
# Bring up (three workers for the NATS servers, no default CNI; Cilium
# comes from this cluster):
#   kind create cluster --name kix-keda --kubeconfig /tmp/kc-keda --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Build:    nix run .#kix -- check keda
# Deploy:   KUBECONFIG=/tmp/kc-keda nix run .#kix -- deploy keda --context kind-kix-keda -y

{ kix, packages }:

let
  # The scale target, the Job that creates the stream and consumer the
  # trigger reads, and the ScaledObject.
  workerPackage =
    { scope, kix, ... }:
    let
      name = scope.instanceName;
      podSecurity = {
        runAsNonRoot = true;
        runAsUser = 1000;
        runAsGroup = 1000;
        seccompProfile.type = "RuntimeDefault";
      };
      hardening = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
      };
    in
    {
      meta = {
        description = "Worker scaled by KEDA from Prometheus and NATS JetStream";
        owner = "app-team";
      };

      options = {
        image = kix.options.image {
          repository = "docker.io/nginxinc/nginx-unprivileged";
          tag = "1.27-alpine";
          digest = "sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0";
        };
        boxImage = kix.options.image {
          repository = "docker.io/natsio/nats-box";
          tag = "0.20.2";
          digest = "sha256:5162fca0f56ebe6f78e612e1ded143ce978e088393476033020e6251358dba6f";
        };
      };

      build =
        {
          self,
          config,
          keda,
          prometheus,
          nats,
          natsLogin,
          ...
        }:
        {
          # KEDA owns spec.replicas, so the Deployment leaves it out.
          worker = scope.mkDeployment {
            inherit name;
            spec = {
              selector.matchLabels = scope.selectorLabels // {
                "app.kubernetes.io/component" = "worker";
              };
              template.spec = {
                securityContext = podSecurity // {
                  runAsUser = 101;
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
                    securityContext = hardening;
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
                  {
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
                          || nats stream add events --subjects 'events.>' \
                               --storage file --replicas 3 --defaults
                        nats consumer info events worker >/dev/null 2>&1 \
                          || nats consumer add events worker --pull --defaults
                      ''
                    ];
                    # The nats CLI keeps its contexts under $HOME.
                    env = kix.mkEnvVars {
                      NATS_URL = nats.out.url;
                      NATS_USER = natsLogin.out.keyRef "username";
                      NATS_PASSWORD = natsLogin.out.keyRef "password";
                      HOME = "/tmp";
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
                    securityContext = hardening;
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
            # The trigger reads the consumer the Job creates.
            requires = [ self.streams ];
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
                    # The monitoring address opens the operator's egress to
                    # the NATS servers on port 8222 only, in any namespace.
                    natsServerMonitoringEndpoint = "${nats.out.monitoringHost}:${nats.out.monitoringPort}";
                    # The global account, as the servers configure none.
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

  # Test values only.
  natsLogin = {
    username = "app";
    password = "test-only-password";
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
        # The NATS servers run at availability `pod`; see the header.
        cluster.capabilities.multiNode = true;
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

        instances.messaging = {
          nats = {
            package = packages.experimental.nats;
            availability = "pod";
            config = {
              clustered = true;
              storage.size = "1Gi";
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "256Mi";
                };
                limits = {
                  cpu = "100m";
                  memory = "256Mi";
                };
              };
            };
          };
          nats-auth = {
            package = packages.secret;
            aliases = [ "natsAuth" ];
            config.stringData = natsLogin;
          };
        };

        instances.app = {
          nats-login = {
            package = packages.secret;
            aliases = [ "natsLogin" ];
            config.stringData = natsLogin;
          };
          worker = {
            package = workerPackage;
            deps = {
              prometheus = ref.monitoring.prometheus;
              nats = ref.messaging.nats;
            };
          };
        };
      }
    )
  ];
}
