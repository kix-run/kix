# clusters/test-nats.nix: two NATS instances in two namespaces under Cilium
# default deny, with clients in their own and in other namespaces.
#
# `messaging-prod/nats` sets `clustered` and runs at availability `pod`, so
# `replicas` takes its default of 3 and the servers form a cluster over the
# headless Service. `messaging-dev/nats` keeps the default, one standalone
# server at the cluster's level `none`, and sets a `settings` key. Each
# requires a login from its namespace's `nats-auth` secret (test values
# only). Both run JetStream on a 1Gi volume per pod, and both have the
# exporter sidecar, a ServiceMonitor, and alerts through
# prometheus-operator, which test-nats.rules-test.yaml tests.
#
# Each NATS namespace has a `client` that takes the instance as its `nats`
# dependency, reads `out.url` and `out.credentials`, creates the stream
# KIX_TEST with as many replicas as there are servers, and publishes to it
# every 30 seconds. It turns ready once the stream exists. In
# messaging-prod, `poller` reads only `out.monitoringHost` and
# `out.monitoringPort` and polls /healthz, so its policy admits port 8222
# and not 4222, and `stranger` takes no dependency, so no policy admits it
# to either port.
#
# Consumers in other namespaces name the instance with `ref`. In `apps`,
# `remote-client` reads `out.url` of messaging-prod/nats and logs in with
# `apps/nats-login`, a copy of the login in its own namespace, because a
# Secret reference resolves only in the pod's namespace. `scaler` in
# `scaling` stands in for an autoscaler operator: its PollTarget custom
# resources tell its pods which address to poll, and the CRD declares that
# those pods dial what a PollTarget's spec names (`factBehavior`). The
# PollTarget in `apps` carries `out.monitoringHost:out.monitoringPort`, so
# the scaler pods get port 8222 of messaging-prod/nats and nothing else.
# The scaler pod reads no PollTarget; a live test polls the address from it
# by hand.
#
# Bring up (three workers, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-nats --kubeconfig /tmp/kc-nats --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Build:   kix build nats
# Deploy:  KUBECONFIG=/tmp/kc-nats kix deploy nats --context kind-kix-nats -y

{ kix, packages }:

let
  natsBox = "docker.io/natsio/nats-box:0.20.2@sha256:5162fca0f56ebe6f78e612e1ded143ce978e088393476033020e6251358dba6f";

  # A nats-box Deployment running `script`, with the variables `env`
  # returns from the build arguments and a readiness command. With
  # `withNats`, the build takes the `nats` dependency.
  natsBoxPackage =
    {
      description,
      withNats ? true,
      withLogin ? false,
      env,
      script,
      ready,
    }:
    let
      body =
        {
          self,
          scope,
          kix,
          ...
        }@args:
        let
          labels = scope.selectorLabels;
          check = {
            exec.command = [
              "sh"
              "-c"
              ready
            ];
            periodSeconds = 10;
            timeoutSeconds = 5;
          };
        in
        {
          deployment =
            {
              name = scope.instanceName;
              availability.max = "none";
              spec = {
                replicas = 1;
                selector.matchLabels = labels;
                template = {
                  metadata.labels = labels;
                  spec = {
                    automountServiceAccountToken = false;
                    enableServiceLinks = false;
                    # The Kubernetes default; the script needs no longer to
                    # stop.
                    terminationGracePeriodSeconds = 30;
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      {
                        name = "nats-box";
                        image = natsBox;
                        # The image's working directory is /root, which
                        # uid 1000 cannot read, and the nats CLI fails when
                        # it cannot read its working directory.
                        workingDir = "/tmp";
                        command = [
                          "sh"
                          "-c"
                          script
                        ];
                        # The nats CLI keeps its contexts under
                        # XDG_CONFIG_HOME, which the image points at /nsc.
                        env = kix.mkEnvVars (
                          {
                            HOME = "/tmp";
                            XDG_CONFIG_HOME = "/tmp/.config";
                            XDG_DATA_HOME = "/tmp/.data";
                          }
                          // env args
                        );
                        readinessProbe = check;
                        livenessProbe = check // {
                          failureThreshold = 30;
                        };
                        resources = {
                          requests = {
                            cpu = "10m";
                            memory = "32Mi";
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
                      }
                    ];
                  };
                };
              };
            }
            |> kix.withMountsOn "nats-box" [
              (kix.mount.emptyDir {
                name = "tmp";
                mountPath = "/tmp";
                sizeLimit = "16Mi";
              })
            ]
            |> scope.mkDeployment;
          root = self.deployment;
        };
    in
    {
      meta = {
        inherit description;
        owner = "app-team";
      };
      build =
        if withLogin then
          {
            self,
            scope,
            kix,
            lib,
            nats,
            natsLogin,
            ...
          }@args:
          body args
        else if withNats then
          {
            self,
            scope,
            kix,
            lib,
            nats,
            ...
          }@args:
          body args
        else
          {
            self,
            scope,
            kix,
            lib,
            ...
          }@args:
          body args;
    };

  # Creates the stream KIX_TEST with `replicas` copies and publishes to it,
  # logging in with `login` of the build arguments.
  clientPackage =
    {
      replicas,
      login ? args: args.nats.out.credentials,
      withLogin ? false,
    }:
    natsBoxPackage {
      description = "NATS client stand-in that publishes to a JetStream stream";
      inherit withLogin;
      env =
        { nats, ... }@args:
        {
          NATS_URL = nats.out.url;
          STREAM_REPLICAS = toString replicas;
          NATS_USER = (login args).out.keyRef "username";
          NATS_PASSWORD = (login args).out.keyRef "password";
        };
      script = ''
        set -u
        until nats stream info KIX_TEST >/dev/null 2>&1 \
          || nats stream add KIX_TEST --subjects 'kix.test.>' --storage file \
               --replicas "$STREAM_REPLICAS" --defaults; do
          sleep 5
        done
        while true; do
          nats pub kix.test.tick "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
          nats stream info KIX_TEST || true
          sleep 30
        done
      '';
      ready = "nats stream info KIX_TEST >/dev/null";
    };

  # Polls the monitoring endpoint and reads nothing else of the instance.
  pollerPackage = natsBoxPackage {
    description = "Monitoring poller stand-in that reads NATS /healthz";
    env =
      { nats, ... }:
      {
        MONITOR = "${nats.out.monitoringHost}:${nats.out.monitoringPort}";
      };
    script = ''
      while true; do
        wget -qO- "http://$MONITOR/healthz" || true
        echo
        sleep 30
      done
    '';
    ready = "wget -qO- \"http://$MONITOR/healthz\" >/dev/null";
  };

  # Takes no dependency, so no policy admits it to NATS.
  strangerPackage = natsBoxPackage {
    description = "Pod with no NATS dependency, for checking that policy refuses it";
    withNats = false;
    env = _: { };
    script = "while true; do sleep 3600; done";
    ready = "true";
  };

  # Stands in for an autoscaler operator in another namespace. Its pods
  # dial the address each PollTarget names, which the CRD declares through
  # `factBehavior`, so Kix opens their egress to it.
  scalerPackage =
    let
      operator = strangerPackage;
    in
    operator
    // {
      meta = {
        description = "Autoscaler operator stand-in that polls addresses named in PollTarget resources";
        owner = "platform";
      };
      build =
        {
          self,
          scope,
          kix,
          lib,
          ...
        }@args:
        operator.build args
        // {
          pollTargets = scope.mkCRD {
            spec = {
              group = "scaling.kix.test";
              names = {
                kind = "PollTarget";
                plural = "polltargets";
              };
              scope = "Namespaced";
              versions = [
                {
                  name = "v1";
                  served = true;
                  storage = true;
                  schema.openAPIV3Schema = {
                    type = "object";
                    properties.spec = {
                      type = "object";
                      properties.endpoint.type = "string";
                    };
                  };
                }
              ];
            };
            holdsData = false;
            factBehavior = {
              endpoint = "terminate";
              podSelector = scope.selectorLabels;
              podNamespace = scope.namespaceName;
            };
          };
          root = {
            resource = self.deployment;
            out.crds.PollTarget = self.pollTargets;
            requires = [ self.pollTargets ];
          };
        };
    };

  # A PollTarget for the monitoring address of its `nats` dependency.
  pollTargetPackage = {
    meta = {
      description = "PollTarget naming a NATS monitoring endpoint";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        nats,
        scaler,
        ...
      }:
      {
        target = scope.mkCR scaler.out.crds.PollTarget {
          name = scope.instanceName;
          spec.endpoint = "${nats.out.monitoringHost}:${nats.out.monitoringPort}";
        };
        root = self.target;
      };
  };

  # Test values only.
  natsLogin = {
    username = "app";
    password = "test-only-password";
  };
in
kix.buildCluster {
  name = "test-nats";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        # Availability `pod` needs more than one node; see the header.
        cluster.capabilities.multiNode = true;
        cluster.availability.default = "none";

        instances.kube-system.cilium.package = packages.experimental.cilium;
        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

        instances.messaging-prod = {
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
          client = {
            package = clientPackage { replicas = 3; };
            deps.nats = ref.messaging-prod.nats;
          };
          poller = {
            package = pollerPackage;
            deps.nats = ref.messaging-prod.nats;
          };
          stranger.package = strangerPackage;
        };

        instances.messaging-dev = {
          nats = {
            package = packages.experimental.nats;
            config = {
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
              settings.max_payload = 2097152;
            };
          };
          nats-auth = {
            package = packages.secret;
            aliases = [ "natsAuth" ];
            config.stringData = natsLogin // {
              password = "test-only-dev-password";
            };
          };
          client = {
            package = clientPackage { replicas = 1; };
            deps.nats = ref.messaging-dev.nats;
          };
        };

        instances.apps = {
          nats-login = {
            package = packages.secret;
            aliases = [ "natsLogin" ];
            config.stringData = natsLogin;
          };
          remote-client = {
            package = clientPackage {
              replicas = 3;
              withLogin = true;
              login = args: args.natsLogin;
            };
            deps.nats = ref.messaging-prod.nats;
          };
          nats-poll = {
            package = pollTargetPackage;
            deps = {
              nats = ref.messaging-prod.nats;
              scaler = ref.scaling.scaler;
            };
          };
        };

        instances.scaling.scaler.package = scalerPackage;
      }
    )
  ];
}
