# metrics-server: the Kubernetes resource metrics API (metrics.k8s.io),
# which HorizontalPodAutoscalers, `kubectl top`, and the descheduler's
# KubernetesMetrics source read. It scrapes every kubelet's
# /metrics/resource endpoint and serves the latest CPU and memory usage of
# nodes and pods as an aggregated API. root = the Deployment.
#
# Installs a ServiceAccount; ClusterRole and ClusterRoleBinding
# <name>-<namespace> for the nodes, pods, and nodes/metrics it reads;
# ClusterRole <name>-<namespace>-aggregated-reader, which the
# aggregate-to-view, aggregate-to-edit, and aggregate-to-admin labels fold
# into the built-in view, edit, and admin roles; ClusterRoleBinding
# <name>-<namespace>-auth-delegator to system:auth-delegator; RoleBinding
# <name>-<namespace>-auth-reader in kube-system to
# extension-apiserver-authentication-reader; the Deployment; Service <name>
# on 443; and APIService v1beta1.metrics.k8s.io pointing at the Service.
#
# The instance claims the `metricsApi` role, and the APIService name is
# fixed, so a cluster runs one. Flavours whose environment serves
# metrics.k8s.io itself (rke2, k3s, GKE, AKS, OpenShift) bind the role
# `exclusive`, so this
# package is refused there at evaluation. No dependency or option is
# required:
#
#   instances.metrics-server.metrics-server.package = packages.experimental.metrics-server;
#
# The package has no `replicas` option: it serves the API to every caller
# through the APIService, so the availability level sets the count (one
# below `pod`, two from `pod` up), and every replica scrapes every kubelet.
#
# Kubelet TLS: metrics-server verifies each kubelet's serving certificate
# against the cluster CA. Where kubelets serve self-signed certificates
# (kind, kubeadm without `serverTLSBootstrap: true` in its
# KubeletConfiguration, and Talos without kubelet certificate rotation),
# either have the kubelets request CA-signed serving certificates and
# approve their CSRs, or add `extraArgs = [ "--kubelet-insecure-tls" ];`
# (clusters/test-metrics-server.nix).
#
# `out`: `version`, the metrics-server version `image.tag` names, beyond what
# root (the Deployment) provides; consumers find the API through the
# cluster's metricsApi role.
#
# Alerts: none. metrics-server serves /metrics only on its secure port,
# behind delegated authentication and authorization, so a scrape must send
# a bearer token. `kix.monitor` sets no token on its primary endpoint, so
# the package renders no ServiceMonitor and has no series of its own to
# alert on. The API server's view covers the outage
# that matters: prometheus-default-rules' KubeAggregatedAPIDown fires when
# APIService v1beta1.metrics.k8s.io is unavailable, and
# KubeAggregatedAPIErrors when requests to it fail. Pods that crash or are
# not ready are left to KubePodCrashLooping and
# KubeDeploymentReplicasMismatch. A kubelet that metrics-server fails to
# scrape while the API stays up drops its node and pods from the API
# (`kubectl top` and HorizontalPodAutoscalers report missing metrics), and
# no rule catches that.
#
# Upgrades: metrics-server keeps no state, and its RBAC, Service, and
# APIService are the same in 0.9.0 and 0.9.1, so 0.9.1 runs on what 0.9.0
# left behind. Upstream documents no upgrade or downgrade path. Going back
# means deploying an older package, such as 0.9.0, over this one. The pods
# restart.
#
# Escape hatches: `extraArgs` (the secure port, certificate directory, bind
# address, and kubelet port flags are refused), `env`, and `partsOverlays`.
#
# Known limits:
# - The APIService sets insecureSkipTLSVerify, as upstream does, because
#   the server signs its own certificate in an emptyDir at startup; the API
#   server does not verify it.
# - Network policy admits egress to the kubelets on 10250 at every node
#   address. `--kubelet-use-node-status-port` takes each kubelet's port from
#   its Node status, so a kubelet on another port is unreachable under
#   default deny.
# - The secure port is fixed at 10250, which EKS reserves on Fargate nodes,
#   so the pods cannot run on Fargate.
# - No ServiceMonitor (see Alerts above).

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "0.9.1";

  name = scope.instanceName;
  securePort = 10250;
  # The kubelet's default port; see the known limits in the header.
  kubeletPort = 10250;
  certDir = "/tmp";

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = release;
    description = "Kubernetes metrics-server, which serves the resource metrics API (metrics.k8s.io) that HorizontalPodAutoscalers and kubectl top read";
    owner = "platform";
    # The role admits one managed claimant per cluster, which also keeps a
    # second APIService v1beta1.metrics.k8s.io out.
    roles = [ "metricsApi" ];
    # The Kubernetes versions metrics-server 0.9.x supports, from the
    # compatibility matrix in its README ("0.9.x ... 1.34+"). The matrix
    # states no upper bound. Move the lower bound with `release`.
    k8s = {
      minVersion = "1.34";
      reason = "metrics-server ${release} supports Kubernetes 1.34 and later. Deploy a Kix release with an older metrics-server package, or move the cluster to a supported Kubernetes version first";
    };
    network.intents = {
      # The API server proxies metrics.k8s.io requests to the pods.
      aggregatedApi.ingress = [
        {
          from = "apiserver";
          ports = [ (tcp securePort) ];
        }
      ];
      # Every kubelet's /metrics/resource. Kubelets run on the host
      # network, so they are reached as Cilium's `host` and `remote-node`
      # entities.
      kubelets.egress = [
        {
          to = "world";
          entities = [
            "host"
            "remote-node"
          ];
          ports = [ (tcp kubeletPort) ];
        }
      ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/metrics-server/metrics-server";
      tag = "v${release}";
      digest = "sha256:9b0ba1926e1d3089673f45461c3c1416109dea33b3ba3434048defd380df329b";
    };

    # No limits: upstream sets none, and usage grows with the number of
    # nodes and pods (metrics-server README, "Scaling").
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "200Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--kubelet-insecure-tls" ];
      description = "Flags appended after the package's own. A repeated flag takes the later value, so `--metric-resolution` and `--kubelet-preferred-address-types` override the package's. `--secure-port`, `--cert-dir`, `--bind-address`, and `--kubelet-port` are refused.";
    };

    env = kix.options.env;
  };

  build =
    { self, config, ... }:
    let
      inherit (scope.rbac)
        core
        group
        grant
        allow
        sub
        watch
        mkClusterRoleSet
        ;
      metrics = group "metrics.k8s.io" [
        "nodes"
        "pods"
      ];
      qualified = "${name}-${scope.namespaceName}";

      subjects = [
        {
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = scope.namespaceName;
        }
      ];

      # metrics-server parses flags with cobra and pflag
      # (cmd/metrics-server/app/start.go upstream).
      args = kix.mergeArgs {
        inherit scope;
        parser = "gnu";
        args = [
          {
            flags = [ "--cert-dir=${certDir}" ];
            reason = "the serving certificate is written to the emptyDir volume at ${certDir}, the only writable path in the container.";
          }
          {
            flags = [ "--secure-port=${toString securePort}" ];
            reason = "the Service, probes, and network policy use port ${toString securePort}.";
          }
          "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"
          "--kubelet-use-node-status-port"
          "--metric-resolution=15s"
          {
            names = [ "--bind-address" ];
            reason = "the probes and the Kubernetes API server connect to the pod IP.";
          }
          {
            names = [ "--kubelet-port" ];
            reason = "the network policy allows traffic to kubelets on port ${toString kubeletPort} only.";
          }
        ];
      } config.extraArgs;
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
      };

      tmpMount = kix.mount.emptyDir {
        name = "tmp";
        mountPath = certDir;
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 2;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              # The server holds no state; 30 is the Kubernetes default,
              # written out for the reliability.gracefulShutdown rule.
              terminationGracePeriodSeconds = 30;
              # HPAs stop scaling while metrics-server is preempted; upstream
              # components.yaml sets the same class.
              priorityClassName = "system-cluster-critical";
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 1000;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "metrics-server";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  inherit args;
                  env = kix.mkEnvVars (kix.mergeEnv { inherit scope; } config.env);
                  ports = [ (kix.port "https" securePort) ];
                  livenessProbe = {
                    httpGet = {
                      path = "/livez";
                      port = "https";
                      scheme = "HTTPS";
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  # /readyz fails until the first kubelet scrape completes.
                  readinessProbe = {
                    httpGet = {
                      path = "/readyz";
                      port = "https";
                      scheme = "HTTPS";
                    };
                    initialDelaySeconds = 20;
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  inherit (config) resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                }
              ];
            };
          };
        }
        |> kix.withMounts [ self.tmpMount ]
        |> scope.mkDeployment;

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          ports = [
            {
              name = "https";
              port = 443;
              targetPort = "https";
              protocol = "TCP";
              appProtocol = "https";
            }
          ];
        }
        |> scope.mkResource;

      apiService = scope.mkClusterResource {
        apiVersion = "apiregistration.k8s.io/v1";
        kind = "APIService";
        # The API server routes a group and version by this name.
        name = "v1beta1.metrics.k8s.io";
        spec = {
          group = "metrics.k8s.io";
          version = "v1beta1";
          service = {
            name = self.service.out.name;
            namespace = scope.namespaceName;
          };
          groupPriorityMinimum = 100;
          versionPriority = 100;
          insecureSkipTLSVerify = true;
        };
      };

      aggregatedReader = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${qualified}-aggregated-reader";
        labels = scope.selectorLabels // {
          "rbac.authorization.k8s.io/aggregate-to-view" = "true";
          "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
          "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        };
        extra.rules = grant [
          (
            [
              metrics.nodes
              metrics.pods
            ]
            |> watch
          )
        ];
      };

      # Delegated authentication and authorization: the server reviews each
      # caller's token and access through the API server.
      authDelegator = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "${qualified}-auth-delegator";
        labels = scope.selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = "system:auth-delegator";
          };
          inherit subjects;
        };
      };

      # The requestheader client CA the API server proxies with lives in
      # ConfigMap kube-system/extension-apiserver-authentication.
      authReader = (scope.forNamespace "kube-system").mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "${qualified}-auth-reader";
        labels = scope.selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "extension-apiserver-authentication-reader";
          };
          inherit subjects;
        };
      };

      root = {
        resource = self.deployment;
        # Nothing else references these parts, so the PackageInstance
        # reaches them only through this list.
        requires = [
          self.apiService
          self.aggregatedReader
        ];
        out.version = kix.image.version config.image;
      };
    }
    // mkClusterRoleSet scope {
      inherit subjects;
      labels = scope.selectorLabels;
      # metrics-server v0.9.1 components.yaml, ClusterRole system:metrics-server.
      roles.${qualified} = grant [
        (core.nodes |> sub "metrics" |> allow [ "get" ])
        (
          [
            core.pods
            core.nodes
          ]
          |> watch
        )
      ];
    };
}
