# The control plane: agent-core (with agent-ha-cluster in its pod),
# api-rest, operator-diskpool, and csi-controller, and the Services that
# agent-core and api-rest answer on.
{
  self,
  config,
  scope,
  lib,
  kix,
  availability,
  snapshotController ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) name ns;
  ep = c.endpoints self;

  placement = {
    nodeSelector = c.amd64;
    tolerations = c.controlPlaneTolerations;
    priorityClassName = "system-cluster-critical";
    terminationGracePeriodSeconds = 30;
  };

  fieldRef = c.fieldRef;

  csiSocketDir = "/var/lib/csi/sockets/pluginproxy/";
  csiSocket = "${csiSocketDir}csi.sock";

  sidecar = image: args: {
    name = lib.removePrefix "registry.k8s.io/sig-storage/" image.repository;
    image = kix.image.ref image;
    imagePullPolicy = image.pullPolicy;
    args = [
      "--v=2"
      "--csi-address=${csiSocket}"
    ]
    ++ args;
    resources = config.csiSidecars.resources;
    securityContext.readOnlyRootFilesystem = true;
    volumeMounts = [
      {
        name = "socket-dir";
        mountPath = csiSocketDir;
      }
    ];
  };
in
{
  # agent-core is the single writer of Mayastor's records in etcd; a second
  # pod waits on its etcd lease. agent-ha-cluster runs beside it and reaches
  # it over the pod's loopback.
  agentCore = scope.mkDeployment {
    name = "${name}-agent-core";
    availability.max = "none";
    spec = {
      replicas = 1;
      selector.matchLabels = c.componentLabels "agent-core";
      template.spec = placement // {
        serviceAccount = self.agentCoreServiceAccount;
        initContainers = [ (c.waitFor config "etcd" self.etcdService.out.fqdn 2379) ];
        containers = [
          {
            name = "agent-core";
            image = kix.image.ref config.agentCore.image;
            imagePullPolicy = config.agentCore.image.pullPolicy;
            args = c.args {
              option = "agentCore.extraArgs";
              args = [
                {
                  owned = [ "--store=${ep.etcdStore}" ];
                  reason = "the package points it at this instance's etcd.";
                }
                {
                  owned = [ "--grpc-server-addr=[::]:50051" ];
                  reason = "the agent-core Service and its clients use port 50051.";
                }
                {
                  names = [ "-s" ];
                  reason = "the package sets --store to this instance's etcd.";
                }
                {
                  names = [ "-g" ];
                  reason = "the package sets --grpc-server-addr, which the agent-core Service uses.";
                }
              ];
            } config.agentCore.extraArgs;
            env = c.env {
              option = "agentCore.env";
              defaults.RUST_LOG = "info";
              # The namespace is part of the key of every record in etcd.
              owned = {
                MY_POD_NAME = fieldRef "metadata.name";
                MY_POD_NAMESPACE = fieldRef "metadata.namespace";
              };
            } config.agentCore.env;
            ports = [ (kix.port "grpc" 50051) ];
            resources = config.agentCore.resources;
            securityContext.readOnlyRootFilesystem = true;
          }
          {
            name = "agent-ha-cluster";
            image = kix.image.ref config.agentHaCluster.image;
            imagePullPolicy = config.agentHaCluster.image.pullPolicy;
            args = c.args {
              option = "agentHaCluster.extraArgs";
              args = [
                {
                  owned = [ "--grpc-endpoint=[::]:50052" ];
                  reason = "the agent-core Service and agent-ha-node use port 50052.";
                }
                {
                  owned = [ "--store=${ep.etcdUrl}" ];
                  reason = "the package points it at this instance's etcd.";
                }
                {
                  owned = [ "--core-grpc=https://127.0.0.1:50051" ];
                  reason = "agent-core runs in the same pod.";
                }
                {
                  names = [ "-g" ];
                  reason = "the package sets --grpc-endpoint, which the agent-core Service uses.";
                }
                {
                  names = [ "-s" ];
                  reason = "the package sets --store to this instance's etcd.";
                }
                {
                  names = [ "-c" ];
                  reason = "the package sets --core-grpc to agent-core in the same pod.";
                }
              ];
            } config.agentHaCluster.extraArgs;
            env = c.env {
              option = "agentHaCluster.env";
              defaults.RUST_LOG = "info";
              owned = {
                MY_POD_NAME = fieldRef "metadata.name";
                MY_POD_NAMESPACE = fieldRef "metadata.namespace";
              };
            } config.agentHaCluster.env;
            ports = [ (kix.port "ha-cluster" 50052) ];
            resources = config.agentHaCluster.resources;
            securityContext.readOnlyRootFilesystem = true;
          }
        ];
      };
    };
    requires = [ self.agentCoreClusterRoleBinding ];
  };

  agentCoreService =
    self.agentCore
    |> kix.service.fromWorkload {
      name = "${name}-agent-core";
      labels = c.componentLabels "agent-core";
    }
    |> scope.mkResource;

  # api-rest holds no state, so it scales with the availability level.
  apiRest =
    let
      probe = path: periodSeconds: {
        httpGet = {
          inherit path;
          port = 8081;
        };
        initialDelaySeconds = 1;
        inherit periodSeconds;
        timeoutSeconds = 5;
        failureThreshold = 3;
      };
    in
    scope.mkDeployment {
      name = "${name}-api-rest";
      spec = {
        replicas = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        selector.matchLabels = c.componentLabels "api-rest";
        template.spec = placement // {
          serviceAccount = self.apiRestServiceAccount;
          automountServiceAccountToken = false;
          initContainers = [ (c.waitFor config "agent-core" self.agentCoreService.out.fqdn 50051) ];
          containers = [
            {
              name = "api-rest";
              image = kix.image.ref config.apiRest.image;
              imagePullPolicy = config.apiRest.image.pullPolicy;
              # --dummy-certificates serves the HTTPS listener (8080), which
              # the package does not expose, with built-in certificates.
              args = c.args {
                option = "apiRest.extraArgs";
                args = [
                  {
                    owned = [ "--http=[::]:8081" ];
                    reason = "the api-rest Service, the probes, and every client use port 8081.";
                  }
                  {
                    owned = [ "--no-auth" ];
                    from = "the package, and clients send no token";
                  }
                  {
                    owned = [ "--dummy-certificates" ];
                    names = [ "-d" ];
                    from = "the package";
                  }
                  {
                    owned = [ "--core-grpc=${ep.coreGrpc}" ];
                    reason = "the package points it at this instance's agent-core.";
                  }
                  {
                    names = [ "-z" ];
                    reason = "the package sets --core-grpc to this instance's agent-core.";
                  }
                  { defaults = [ "--core-health-freq=20s" ]; }
                ];
              } config.apiRest.extraArgs;
              env = c.env {
                option = "apiRest.env";
                defaults.RUST_LOG = "info";
              } config.apiRest.env;
              ports = [ (kix.port "http" 8081) ];
              readinessProbe = probe "/ready" 20;
              livenessProbe = probe "/live" 30;
              resources = config.apiRest.resources;
              securityContext.readOnlyRootFilesystem = true;
            }
          ];
        };
      };
    };

  apiRestService =
    self.apiRest
    |> kix.service.fromWorkload {
      name = "${name}-api-rest";
      labels = c.componentLabels "api-rest";
    }
    |> scope.mkResource;

  # One operator: it runs no leader election.
  operatorDiskpool = scope.mkDeployment {
    name = "${name}-operator-diskpool";
    availability.max = "none";
    spec = {
      replicas = 1;
      selector.matchLabels = c.componentLabels "operator-diskpool";
      template.spec = placement // {
        serviceAccount = self.operatorDiskpoolServiceAccount;
        initContainers = [ (c.waitFor config "api-rest" self.apiRestService.out.fqdn 8081) ];
        containers = [
          {
            name = "operator-diskpool";
            image = kix.image.ref config.operatorDiskpool.image;
            imagePullPolicy = config.operatorDiskpool.image.pullPolicy;
            args = c.args {
              option = "operatorDiskpool.extraArgs";
              args = [
                {
                  owned = [ "--endpoint=${ep.rest}" ];
                  reason = "the package points it at this instance's api-rest.";
                }
                {
                  owned = [ "--namespace=${ns}" ];
                  reason = "the operator reads DiskPools in this instance's namespace, where its RBAC and the package's DiskPools are.";
                }
                {
                  names = [ "-e" ];
                  reason = "the package sets --endpoint to this instance's api-rest.";
                }
                {
                  names = [ "-n" ];
                  reason = "the package sets --namespace to this instance's namespace.";
                }
              ];
            } config.operatorDiskpool.extraArgs;
            env = c.env {
              option = "operatorDiskpool.env";
              defaults.RUST_LOG = "info";
              owned.MY_POD_NAME = fieldRef "metadata.name";
            } config.operatorDiskpool.env;
            resources = config.operatorDiskpool.resources;
            securityContext.readOnlyRootFilesystem = true;
          }
        ];
      };
    };
    requires = [
      self.operatorDiskpoolClusterRoleBinding
      self.operatorDiskpoolRoleBinding
    ]
    ++ lib.optional (self.operatorDiskpoolKeyRoleBinding != null) self.operatorDiskpoolKeyRoleBinding;
  };

  # One controller: its sidecars run without leader election. Upstream runs
  # it on the host network.
  csiController = scope.mkDeployment {
    name = "${name}-csi-controller";
    availability.max = "none";
    spec = {
      replicas = 1;
      selector.matchLabels = c.componentLabels "csi-controller";
      template.spec = placement // {
        serviceAccount = self.csiControllerServiceAccount;
        hostNetwork = true;
        # Resolve Service names through cluster DNS from the host network.
        dnsPolicy = "ClusterFirstWithHostNet";
        initContainers = [ (c.waitFor config "api-rest" self.apiRestService.out.fqdn 8081) ];
        containers = [
          {
            name = "csi-controller";
            image = kix.image.ref config.csiController.image;
            imagePullPolicy = config.csiController.image.pullPolicy;
            args = c.args {
              option = "csiController.extraArgs";
              args = [
                {
                  owned = [ "--csi-socket=${csiSocket}" ];
                  reason = "the CSI sidecars dial this socket.";
                }
                {
                  owned = [ "--rest-endpoint=${ep.rest}" ];
                  reason = "the package points it at this instance's api-rest.";
                }
                {
                  names = [ "-c" ];
                  reason = "the package sets --csi-socket, which the CSI sidecars dial.";
                }
                {
                  names = [ "-r" ];
                  reason = "the package sets --rest-endpoint to this instance's api-rest.";
                }
              ];
            } config.csiController.extraArgs;
            env = c.env {
              option = "csiController.env";
              defaults.RUST_LOG = "info";
            } config.csiController.env;
            resources = config.csiController.resources;
            securityContext.readOnlyRootFilesystem = true;
            volumeMounts = [
              {
                name = "socket-dir";
                mountPath = csiSocketDir;
              }
            ];
          }
          (sidecar config.csiProvisioner.image [
            "--feature-gates=Topology=true"
            "--strict-topology=false"
            "--default-fstype=ext4"
            # Mayastor's volume groups read the claim's name and namespace.
            "--extra-create-metadata"
            "--timeout=36s"
            "--worker-threads=10"
            "--prevent-volume-mode-conversion"
          ])
          (sidecar config.csiAttacher.image [ "--timeout=36s" ])
          (sidecar config.csiResizer.image [ "--handle-volume-inuse-error=false" ])
        ]
        ++ lib.optional (snapshotController != null) (sidecar config.csiSnapshotter.image [ ]);
        volumes = [
          {
            name = "socket-dir";
            emptyDir = { };
          }
        ];
      };
    };
    requires = [
      self.csiDriver
      self.csiControllerClusterRoleBinding
    ]
    ++ lib.optionals (snapshotController != null) (builtins.attrValues snapshotController.out.crds);
  };
}
