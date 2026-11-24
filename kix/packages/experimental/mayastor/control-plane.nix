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
                  flags = [ "--store=${ep.etcdStore}" ];
                  reason = "agent-core must connect to this instance's etcd Service.";
                }
                {
                  flags = [ "--grpc-server-addr=[::]:50051" ];
                  reason = "the agent-core Service and its clients use port 50051.";
                }
                {
                  names = [ "-s" ];
                  reason = "-s is the short form of --store, which connects agent-core to this instance's etcd Service.";
                }
                {
                  names = [ "-g" ];
                  reason = "-g is the short form of --grpc-server-addr, and the agent-core Service uses port 50051.";
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
                  flags = [ "--grpc-endpoint=[::]:50052" ];
                  reason = "the agent-core Service and agent-ha-node use port 50052.";
                }
                {
                  flags = [ "--store=${ep.etcdUrl}" ];
                  reason = "agent-ha-cluster must connect to this instance's etcd Service.";
                }
                {
                  flags = [ "--core-grpc=https://127.0.0.1:50051" ];
                  reason = "agent-core listens on 127.0.0.1:50051 in the same pod.";
                }
                {
                  names = [ "-g" ];
                  reason = "-g is the short form of --grpc-endpoint, and the agent-core Service uses port 50052.";
                }
                {
                  names = [ "-s" ];
                  reason = "-s is the short form of --store, which connects agent-ha-cluster to this instance's etcd Service.";
                }
                {
                  names = [ "-c" ];
                  reason = "-c is the short form of --core-grpc, and agent-core runs in the same pod.";
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
                    flags = [ "--http=[::]:8081" ];
                    reason = "the api-rest Service, the probes, and every client use port 8081.";
                  }
                  {
                    flags = [ "--no-auth" ];
                    reason = "in-cluster clients connect to api-rest without a token.";
                  }
                  {
                    flags = [ "--dummy-certificates" ];
                    names = [ "-d" ];
                    reason = "this package does not expose the HTTPS listener on port 8080 and uses built-in certificates for it.";
                  }
                  {
                    flags = [ "--core-grpc=${ep.coreGrpc}" ];
                    reason = "api-rest must connect to this instance's agent-core Service.";
                  }
                  {
                    names = [ "-z" ];
                    reason = "-z is the short form of --core-grpc, which connects api-rest to this instance's agent-core Service.";
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
                  flags = [ "--endpoint=${ep.rest}" ];
                  reason = "the DiskPool operator must connect to this instance's api-rest Service.";
                }
                {
                  flags = [ "--namespace=${ns}" ];
                  reason = "the operator's RBAC and DiskPool resources are scoped to namespace \"${ns}\".";
                }
                {
                  names = [ "-e" ];
                  reason = "-e is the short form of --endpoint, which connects the operator to this instance's api-rest Service.";
                }
                {
                  names = [ "-n" ];
                  reason = "-n is the short form of --namespace, and the operator's RBAC and DiskPools are in namespace \"${ns}\".";
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
                  flags = [ "--csi-socket=${csiSocket}" ];
                  reason = "the CSI sidecar containers connect to ${csiSocket}.";
                }
                {
                  flags = [ "--rest-endpoint=${ep.rest}" ];
                  reason = "the CSI controller must connect to this instance's api-rest Service.";
                }
                {
                  names = [ "-c" ];
                  reason = "-c is the short form of --csi-socket, and the CSI sidecar containers connect to ${csiSocket}.";
                }
                {
                  names = [ "-r" ];
                  reason = "-r is the short form of --rest-endpoint, which connects the CSI controller to this instance's api-rest Service.";
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
