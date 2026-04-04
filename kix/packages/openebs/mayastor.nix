# Mayastor — Replicated Block Storage
#
# etcd, NATS, control plane (agent-core), api-rest, operator-diskpool,
# csi-controller, csi-node, io-engine, agent-ha-node, storage classes + RBAC.
{
  self,
  config,
  clusterConfig,
  scope,
  lib,
}:
let
  common = import ./common.nix { inherit scope lib; };
  inherit (common)
    name
    ns
    mayastorLabels
    mayastorSelector
    controlPlaneTolerations
    core
    grant
    full
    watch
    allow
    mkClusterRoleSet
    openebsGrp
    storage
    snap
    apiext
    appsGrp
    ;

  # --- CPU list for io-engine (e.g. "1,2" for cpuCount=2) ---
  cpuList =
    let
      indices = lib.genList (i: toString (i + 1)) config.mayastor.ioEngine.cpuCount;
    in
    builtins.concatStringsSep "," indices;

  # ── Mayastor RBAC ────────────────────────────────────────
  mayastorClusterRoles =
    if config.mayastor.enabled then
      mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.mayastorSa.out.name;
            namespace = ns;
          }
        ];
        labels = mayastorLabels;
        roles = {
          "${name}-cluster-role" = grant [
            (
              apiext.customresourcedefinitions
              |> allow [
                "create"
                "get"
                "update"
                "list"
                "patch"
                "replace"
              ]
            )
            (
              apiext "customresourcedefinitions/status"
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (
              openebsGrp.mayastorpools
              |> allow [
                "get"
                "list"
                "patch"
                "delete"
                "deletecollection"
              ]
            )
            (
              openebsGrp.diskpools
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "replace"
                "patch"
                "create"
              ]
            )
            (
              openebsGrp "diskpools/status"
              |> allow [
                "update"
                "patch"
              ]
            )
            (
              core.configmaps
              |> allow [
                "create"
                "get"
                "update"
                "patch"
              ]
            )
            (
              appsGrp.deployments
              |> allow [
                "get"
                "list"
              ]
            )
            (core.persistentvolumes |> full)
            (
              core.nodes
              |> allow [
                "get"
                "list"
                "watch"
                "patch"
              ]
            )
            (
              core.persistentvolumeclaims
              |> allow [
                "get"
                "list"
                "watch"
                "update"
              ]
            )
            (storage.storageclasses |> watch)
            (
              core.events
              |> allow [
                "list"
                "watch"
                "create"
                "update"
                "patch"
              ]
            )
            (core.pods |> watch)
            (core "persistentvolumeclaims/status" |> allow [ "patch" ])
            (snap.volumesnapshotclasses |> watch)
            (snap.volumesnapshotcontents |> full)
            (
              snap "volumesnapshotcontents/status"
              |> allow [
                "update"
                "patch"
              ]
            )
            (
              snap.volumesnapshots
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
                "delete"
              ]
            )
            (
              snap "volumesnapshots/status"
              |> allow [
                "update"
                "patch"
              ]
            )
            (
              storage.volumeattachments
              |> allow [
                "get"
                "list"
                "watch"
                "update"
                "patch"
              ]
            )
            (storage "volumeattachments/status" |> allow [ "patch" ])
            (storage.csinodes |> watch)
            (core.secrets |> watch)
          ];
        };
      }
    else
      { };

in
{

  # ==========================================================================
  #  MAYASTOR — Replicated Block Storage
  # ==========================================================================

  # --- ServiceAccount (shared by all Mayastor components) ---
  mayastorSa =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-service-account";
        labels = mayastorLabels;
      })
    else
      null;

  # --- PriorityClass (cluster-critical for Mayastor control plane) ---
  priorityClass =
    if config.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "scheduling.k8s.io/v1";
        kind = "PriorityClass";
        name = "${name}-cluster-critical";
        labels = mayastorLabels;
        extra = {
          value = 1000000000;
          preemptionPolicy = "PreemptLowerPriority";
          description = "Critical pods for OpenEBS Mayastor control plane.";
        };
      })
    else
      null;

  # --- etcd (coordination store for Mayastor) ---

  etcdHeadlessService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-etcd-headless";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
        };
        spec = {
          type = "ClusterIP";
          clusterIP = "None";
          publishNotReadyAddresses = true;
          selector = {
            "app.kubernetes.io/name" = "etcd";
            "app.kubernetes.io/instance" = name;
          };
          ports = [
            {
              name = "client";
              port = 2379;
              targetPort = 2379;
              protocol = "TCP";
            }
            {
              name = "peer";
              port = 2380;
              targetPort = 2380;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  etcdService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-etcd";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
        };
        spec = {
          type = "ClusterIP";
          selector = self.etcdStatefulSet.out.selector;
          ports = [
            {
              name = "client";
              port = 2379;
              targetPort = 2379;
              protocol = "TCP";
            }
            {
              name = "peer";
              port = 2380;
              targetPort = 2380;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  etcdStatefulSet =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${name}-etcd";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
        };
        spec = {
          replicas = config.mayastor.etcd.replicaCount;
          serviceName = "${name}-etcd-headless";
          podManagementPolicy = "Parallel";
          selector.matchLabels = {
            "app.kubernetes.io/name" = "etcd";
            "app.kubernetes.io/instance" = name;
          };
          updateStrategy.type = "RollingUpdate";
          template = {
            metadata.labels = {
              "app.kubernetes.io/name" = "etcd";
              "app.kubernetes.io/instance" = name;
              app = "etcd";
            };
            spec = {
              affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector.matchLabels = {
                    "app.kubernetes.io/name" = "etcd";
                    "app.kubernetes.io/instance" = name;
                  };
                  topologyKey = "kubernetes.io/hostname";
                }
              ];
              securityContext = {
                fsGroup = 1001;
              };
              initContainers = [
                {
                  name = "volume-permissions";
                  image = config.mayastor.image.alpineBash;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "/bin/bash"
                    "-ec"
                    "chown -R 1001:1001 /bitnami/etcd"
                  ];
                  securityContext.runAsUser = 0;
                  volumeMounts = [
                    {
                      name = "data";
                      mountPath = "/bitnami/etcd";
                    }
                  ];
                }
              ];
              containers = [
                {
                  name = "etcd";
                  image = config.mayastor.etcd.image;
                  imagePullPolicy = "IfNotPresent";
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    runAsNonRoot = true;
                    runAsUser = 1001;
                  };
                  env = [
                    {
                      name = "BITNAMI_DEBUG";
                      value = "false";
                    }
                    {
                      name = "MY_POD_IP";
                      valueFrom.fieldRef.fieldPath = "status.podIP";
                    }
                    {
                      name = "MY_POD_NAME";
                      valueFrom.fieldRef.fieldPath = "metadata.name";
                    }
                    {
                      name = "MY_STS_NAME";
                      value = "${name}-etcd";
                    }
                    {
                      name = "ETCDCTL_API";
                      value = "3";
                    }
                    {
                      name = "ETCD_ON_K8S";
                      value = "yes";
                    }
                    {
                      name = "ETCD_START_FROM_SNAPSHOT";
                      value = "no";
                    }
                    {
                      name = "ETCD_DISASTER_RECOVERY";
                      value = "no";
                    }
                    {
                      name = "ETCD_NAME";
                      value = "$(MY_POD_NAME)";
                    }
                    {
                      name = "ETCD_DATA_DIR";
                      value = "/bitnami/etcd/data";
                    }
                    {
                      name = "ETCD_LOG_LEVEL";
                      value = "info";
                    }
                    {
                      name = "ALLOW_NONE_AUTHENTICATION";
                      value = "yes";
                    }
                    {
                      name = "ETCD_ADVERTISE_CLIENT_URLS";
                      value = "http://$(MY_POD_NAME).${name}-etcd-headless.${ns}.svc.cluster.local:2379,http://${name}-etcd.${ns}.svc.cluster.local:2379";
                    }
                    {
                      name = "ETCD_LISTEN_CLIENT_URLS";
                      value = "http://0.0.0.0:2379";
                    }
                    {
                      name = "ETCD_INITIAL_ADVERTISE_PEER_URLS";
                      value = "http://$(MY_POD_NAME).${name}-etcd-headless.${ns}.svc.cluster.local:2380";
                    }
                    {
                      name = "ETCD_LISTEN_PEER_URLS";
                      value = "http://0.0.0.0:2380";
                    }
                    {
                      name = "ETCD_AUTO_COMPACTION_MODE";
                      value = "revision";
                    }
                    {
                      name = "ETCD_AUTO_COMPACTION_RETENTION";
                      value = "100";
                    }
                    {
                      name = "ETCD_INITIAL_CLUSTER_TOKEN";
                      value = "etcd-cluster-k8s";
                    }
                    {
                      name = "ETCD_INITIAL_CLUSTER_STATE";
                      value = "new";
                    }
                    {
                      name = "ETCD_INITIAL_CLUSTER";
                      value = builtins.concatStringsSep "," (
                        lib.genList (
                          i:
                          "${name}-etcd-${toString i}=http://${name}-etcd-${toString i}.${name}-etcd-headless.${ns}.svc.cluster.local:2380"
                        ) config.mayastor.etcd.replicaCount
                      );
                    }
                    {
                      name = "ETCD_CLUSTER_DOMAIN";
                      value = "${name}-etcd-headless.${ns}.svc.cluster.local";
                    }
                    {
                      name = "ETCD_QUOTA_BACKEND_BYTES";
                      value = "8589934592";
                    }
                  ];
                  ports = [
                    {
                      name = "client";
                      containerPort = 2379;
                      protocol = "TCP";
                    }
                    {
                      name = "peer";
                      containerPort = 2380;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    exec.command = [ "/opt/bitnami/scripts/etcd/healthcheck.sh" ];
                    initialDelaySeconds = 60;
                    periodSeconds = 30;
                    timeoutSeconds = 5;
                    failureThreshold = 5;
                  };
                  readinessProbe = {
                    exec.command = [ "/opt/bitnami/scripts/etcd/healthcheck.sh" ];
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 5;
                  };
                  volumeMounts = [
                    {
                      name = "data";
                      mountPath = "/bitnami/etcd";
                    }
                  ];
                }
              ];
            };
          };
          volumeClaimTemplates = [
            {
              metadata.name = "data";
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = config.mayastor.etcd.persistence.size;
                storageClassName = config.mayastor.etcd.persistence.storageClass;
              };
            }
          ];
        };
        requires = [
          self.etcdHeadlessService
          self.etcdStorageClass
        ];
      })
    else
      null;

  # StorageClass for etcd local PV
  etcdStorageClass =
    if config.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        name = "mayastor-etcd-localpv";
        labels = mayastorLabels;
        extra = {
          provisioner = "openebs.io/local";
          volumeBindingMode = "WaitForFirstConsumer";
          reclaimPolicy = "Delete";
          parameters."cas.openebs.io/config" = ''
            - name: StorageType
              value: "hostpath"
            - name: BasePath
              value: "/var/local/openebs/mayastor-etcd"
          '';
        };
      })
    else
      null;

  # --- NATS (messaging for Mayastor events) ---

  natsConfigMap =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-nats-config";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        data."nats.conf" = ''
          # NATS config for OpenEBS Mayastor
          pid_file: "/var/run/nats/nats.pid"
          http: 8222
          server_name: $SERVER_NAME
          cluster {
            port: 6222
            routes [
              ${builtins.concatStringsSep "\n          " (
                lib.genList (
                  i: "nats://${name}-nats-${toString i}.${name}-nats.${ns}:6222"
                ) config.mayastor.nats.replicaCount
              )}
            ]
            cluster_advertise: $CLUSTER_ADVERTISE
            connect_retries: 120
          }
          max_payload: 8MB
          max_pending: 128MB
          lame_duck_duration: 30s
          lame_duck_grace_period: 10s
        '';
      })
    else
      null;

  natsSa =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
      })
    else
      null;

  natsService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        spec = {
          selector = self.natsStatefulSet.out.selector;
          ports = [
            {
              name = "client";
              port = 4222;
              protocol = "TCP";
            }
            {
              name = "cluster";
              port = 6222;
              protocol = "TCP";
            }
            {
              name = "monitor";
              port = 8222;
              protocol = "TCP";
            }
            {
              name = "metrics";
              port = 7777;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  natsStatefulSet =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        spec = {
          replicas = config.mayastor.nats.replicaCount;
          serviceName = "${name}-nats";
          podManagementPolicy = "Parallel";
          selector.matchLabels = {
            "app.kubernetes.io/name" = "nats";
            "app.kubernetes.io/instance" = name;
          };
          template = {
            metadata.labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              app = "nats";
            };
            spec = {
              serviceAccountName = self.natsSa.out.name;
              dnsPolicy = "ClusterFirst";
              shareProcessNamespace = true;
              terminationGracePeriodSeconds = 60;
              volumes = [
                {
                  name = "config-volume";
                  configMap.name = self.natsConfigMap.out.name;
                }
                {
                  name = "pid";
                  emptyDir = { };
                }
              ];
              containers = [
                {
                  name = "nats";
                  image = config.mayastor.nats.image;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "nats-server"
                    "--config"
                    "/etc/nats-config/nats.conf"
                  ];
                  env = [
                    {
                      name = "POD_NAME";
                      valueFrom.fieldRef.fieldPath = "metadata.name";
                    }
                    {
                      name = "SERVER_NAME";
                      value = "$(POD_NAME)";
                    }
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                    {
                      name = "CLUSTER_ADVERTISE";
                      value = "$(POD_NAME).${name}-nats.$(POD_NAMESPACE)";
                    }
                  ];
                  ports = [
                    {
                      name = "client";
                      containerPort = 4222;
                    }
                    {
                      name = "cluster";
                      containerPort = 6222;
                    }
                    {
                      name = "monitor";
                      containerPort = 8222;
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "config-volume";
                      mountPath = "/etc/nats-config";
                    }
                    {
                      name = "pid";
                      mountPath = "/var/run/nats";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/";
                      port = 8222;
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 30;
                    timeoutSeconds = 5;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/";
                      port = 8222;
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 3;
                  };
                  startupProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 8222;
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 90;
                  };
                  lifecycle.preStop.exec.command = [
                    "nats-server"
                    "-sl=ldm=/var/run/nats/nats.pid"
                  ];
                }
                {
                  name = "reloader";
                  image = config.mayastor.nats.reloaderImage;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "nats-server-config-reloader"
                    "-pid"
                    "/var/run/nats/nats.pid"
                    "-config"
                    "/etc/nats-config/nats.conf"
                  ];
                  volumeMounts = [
                    {
                      name = "config-volume";
                      mountPath = "/etc/nats-config";
                    }
                    {
                      name = "pid";
                      mountPath = "/var/run/nats";
                    }
                  ];
                }
                {
                  name = "metrics";
                  image = config.mayastor.nats.exporterImage;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "-connz"
                    "-routez"
                    "-subz"
                    "-varz"
                    "-prefix=nats"
                    "-use_internal_server_id"
                    "-jsz=all"
                    "http://localhost:8222/"
                  ];
                  ports = [
                    {
                      name = "metrics";
                      containerPort = 7777;
                    }
                  ];
                }
              ];
            };
          };
          # NATS is stateless (no VCTs needed)
        };
      })
    else
      null;

  # --- agent-core (Mayastor control plane) ---
  agentCoreService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-agent-core";
        labels = mayastorLabels // {
          app = "agent-core";
        };
        spec = {
          selector = self.agentCoreDeployment.out.selector;
          ports = [
            {
              name = "grpc";
              port = 50051;
              protocol = "TCP";
            }
            {
              name = "ha-cluster";
              port = 50052;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  agentCoreDeployment =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-agent-core";
        labels = mayastorLabels // {
          app = "agent-core";
        };
        spec = {
          replicas = 1;
          selector.matchLabels = mayastorSelector "agent-core";
          template = {
            metadata.labels = mayastorSelector "agent-core" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              serviceAccountName = self.mayastorSa.out.name;
              priorityClassName = self.priorityClass.out.name;
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "etcd-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "agent-core";
                  image = config.mayastor.image.agentCore;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--store=${name}-etcd:2379"
                    "--request-timeout=5s"
                    "--cache-period=30s"
                    "--grpc-server-addr=[::]:50051"
                    "--pool-commitment=250%"
                    "--snapshot-commitment=40%"
                    "--volume-commitment-initial=40%"
                    "--volume-commitment=40%"
                    "--events-url=nats://${name}-nats:4222"
                    "--fmt-style=pretty"
                    "--ansi-colors=true"
                    "--create-volume-limit=10"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "MY_POD_NAME";
                      valueFrom.fieldRef.fieldPath = "metadata.name";
                    }
                    {
                      name = "MY_POD_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  ports = [ { containerPort = 50051; } ];
                  resources = {
                    limits = {
                      cpu = "1000m";
                      memory = "128Mi";
                    };
                    requests = {
                      cpu = "500m";
                      memory = "32Mi";
                    };
                  };
                }
                {
                  name = "agent-ha-cluster";
                  image = config.mayastor.image.agentHaCluster;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "-g=[::]:50052"
                    "--store=http://${name}-etcd:2379"
                    "--core-grpc=https://${name}-agent-core:50051"
                    "--events-url=nats://${name}-nats:4222"
                    "--ansi-colors=true"
                    "--fmt-style=pretty"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "MY_POD_NAME";
                      valueFrom.fieldRef.fieldPath = "metadata.name";
                    }
                    {
                      name = "MY_POD_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  ports = [ { containerPort = 50052; } ];
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                    requests = {
                      cpu = "100m";
                      memory = "16Mi";
                    };
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.etcdService
          self.natsService
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- api-rest (REST API gateway) ---
  apiRestService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-api-rest";
        labels = mayastorLabels // {
          app = "api-rest";
        };
        spec = {
          type = "ClusterIP";
          selector = self.apiRestDeployment.out.selector;
          ports = [
            {
              name = "https";
              port = 8080;
              targetPort = 8080;
              protocol = "TCP";
            }
            {
              name = "http";
              port = 8081;
              targetPort = 8081;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  apiRestDeployment =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-api-rest";
        labels = mayastorLabels // {
          app = "api-rest";
        };
        spec = {
          replicas = 1;
          selector.matchLabels = mayastorSelector "api-rest";
          template = {
            metadata.labels = mayastorSelector "api-rest" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              priorityClassName = self.priorityClass.out.name;
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "agent-core-grpc-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "api-rest";
                  image = config.mayastor.image.apiRest;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--dummy-certificates"
                    "--no-auth"
                    "--http=[::]:8081"
                    "--request-timeout=5s"
                    "--core-grpc=https://${name}-agent-core:50051"
                    "--ansi-colors=true"
                    "--fmt-style=pretty"
                    "--core-health-freq=20s"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                  ];
                  ports = [
                    { containerPort = 8080; }
                    { containerPort = 8081; }
                  ];
                  readinessProbe = {
                    httpGet = {
                      path = "/ready";
                      port = 8081;
                    };
                    failureThreshold = 2;
                    periodSeconds = 20;
                    timeoutSeconds = 5;
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/live";
                      port = 8081;
                    };
                    failureThreshold = 1;
                    periodSeconds = 30;
                    timeoutSeconds = 5;
                  };
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                    requests = {
                      cpu = "50m";
                      memory = "32Mi";
                    };
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.agentCoreService
          self.etcdService
          self.priorityClass
        ];
      })
    else
      null;

  # --- operator-diskpool ---
  operatorDiskpoolDeployment =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-operator-diskpool";
        labels = mayastorLabels // {
          app = "operator-diskpool";
        };
        spec = {
          replicas = 1;
          selector.matchLabels = mayastorSelector "operator-diskpool";
          template = {
            metadata.labels = mayastorSelector "operator-diskpool" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              serviceAccountName = self.mayastorSa.out.name;
              priorityClassName = self.priorityClass.out.name;
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "agent-core-grpc-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "operator-diskpool";
                  image = config.mayastor.image.operatorDiskpool;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "-e http://${name}-api-rest:8081"
                    "-n${ns}"
                    "--request-timeout=5s"
                    "--interval=30s"
                    "--ansi-colors=true"
                    "--fmt-style=pretty"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "MY_POD_NAME";
                      valueFrom.fieldRef.fieldPath = "metadata.name";
                    }
                  ];
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "32Mi";
                    };
                    requests = {
                      cpu = "50m";
                      memory = "16Mi";
                    };
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.apiRestService
          self.agentCoreService
          self.etcdService
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- csi-controller (Mayastor CSI provisioner/attacher/snapshotter) ---
  csiControllerDeployment =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-csi-controller";
        labels = mayastorLabels // {
          app = "csi-controller";
        };
        spec = {
          replicas = config.mayastor.csiController.replicas;
          selector.matchLabels = mayastorSelector "csi-controller";
          template = {
            metadata.labels = mayastorSelector "csi-controller" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              hostNetwork = true;
              serviceAccountName = self.mayastorSa.out.name;
              dnsPolicy = "ClusterFirstWithHostNet";
              priorityClassName = self.priorityClass.out.name;
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "api-rest-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-api-rest 8081; do date; echo \"Waiting for REST API...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "csi-provisioner";
                  image = config.mayastor.csiController.csiProvisioner;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--csi-address=$(ADDRESS)"
                    "--feature-gates=Topology=true"
                    "--strict-topology=false"
                    "--default-fstype=ext4"
                    "--extra-create-metadata"
                    "--timeout=36s"
                    "--worker-threads=10"
                    "--prevent-volume-mode-conversion"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "socket-dir";
                      mountPath = "/var/lib/csi/sockets/pluginproxy/";
                    }
                  ];
                }
                {
                  name = "csi-attacher";
                  image = config.mayastor.csiController.csiAttacher;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--timeout=36s"
                    "--csi-address=$(ADDRESS)"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "socket-dir";
                      mountPath = "/var/lib/csi/sockets/pluginproxy/";
                    }
                  ];
                }
                {
                  name = "csi-snapshotter";
                  image = config.mayastor.csiController.csiSnapshotter;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--csi-address=$(ADDRESS)"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "socket-dir";
                      mountPath = "/var/lib/csi/sockets/pluginproxy/";
                    }
                  ];
                }
                {
                  name = "csi-snapshot-controller";
                  image = config.mayastor.csiController.snapshotController;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--leader-election=false"
                    "--prevent-volume-mode-conversion"
                  ];
                }
                {
                  name = "csi-resizer";
                  image = config.mayastor.csiController.csiResizer;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--csi-address=$(ADDRESS)"
                    "--handle-volume-inuse-error=false"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "socket-dir";
                      mountPath = "/var/lib/csi/sockets/pluginproxy/";
                    }
                  ];
                }
                {
                  name = "csi-controller";
                  image = config.mayastor.image.csiController;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-socket=/var/lib/csi/sockets/pluginproxy/csi.sock"
                    "--rest-endpoint=http://${name}-api-rest:8081"
                    "--node-selector=openebs.io/csi-node=mayastor"
                    "--ansi-colors=true"
                    "--fmt-style=pretty"
                    "--create-volume-limit=10"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "socket-dir";
                      mountPath = "/var/lib/csi/sockets/pluginproxy/";
                    }
                  ];
                  resources = {
                    limits = {
                      cpu = "32m";
                      memory = "128Mi";
                    };
                    requests = {
                      cpu = "16m";
                      memory = "64Mi";
                    };
                  };
                }
              ];
              volumes = [
                {
                  name = "socket-dir";
                  emptyDir = { };
                }
              ];
            };
          };
        };
        requires = [
          self.apiRestService
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- csi-node DaemonSet (Mayastor CSI node plugin) ---
  csiNodeDaemonSet =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-csi-node";
        labels = mayastorLabels // {
          app = "csi-node";
          "openebs.io/csi-node" = "mayastor";
        };
        spec = {
          selector.matchLabels = mayastorSelector "csi-node";
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          minReadySeconds = 10;
          template = {
            metadata.labels = mayastorSelector "csi-node" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              serviceAccountName = self.mayastorSa.out.name;
              hostNetwork = true;
              dnsPolicy = "ClusterFirstWithHostNet";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              containers = [
                {
                  name = "csi-node";
                  image = config.mayastor.image.csiNode;
                  imagePullPolicy = "IfNotPresent";
                  securityContext.privileged = true;
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "MY_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "MY_POD_IP";
                      valueFrom.fieldRef.fieldPath = "status.podIP";
                    }
                    {
                      name = "RUST_BACKTRACE";
                      value = "1";
                    }
                  ];
                  args = [
                    "--csi-socket=/csi/csi.sock"
                    "--node-name=$(MY_NODE_NAME)"
                    "--rest-endpoint=http://${name}-api-rest:8081"
                    "--enable-rest"
                    "--enable-registration"
                    "--grpc-ip=$(MY_POD_IP)"
                    "--grpc-port=10199"
                    "--nvme-io-timeout=110s10s"
                    "--nvme-core-io-timeout=110s10s"
                    "--nvme-ctrl-loss-tmo=1980"
                    "--nvme-nr-io-queues=2"
                    "--nvme-connect-fallback=true"
                    "--kubelet-path=/var/lib/kubelet"
                    "--node-selector=openebs.io/csi-node=mayastor"
                    "--fmt-style=pretty"
                    "--ansi-colors=true"
                  ];
                  volumeMounts = [
                    {
                      name = "device";
                      mountPath = "/dev";
                    }
                    {
                      name = "sys";
                      mountPath = "/sys";
                    }
                    {
                      name = "run-udev";
                      mountPath = "/run/udev";
                    }
                    {
                      name = "plugin-dir";
                      mountPath = "/csi";
                    }
                    {
                      name = "kubelet-dir";
                      mountPath = "/var/lib/kubelet";
                      mountPropagation = "Bidirectional";
                    }
                  ];
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "128Mi";
                    };
                    requests = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                  };
                }
                {
                  name = "csi-driver-registrar";
                  image = config.mayastor.csiNodeRegistrar;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-address=/csi/csi.sock"
                    "--kubelet-registration-path=/var/lib/kubelet/plugins/io.openebs.mayastor/csi.sock"
                  ];
                  volumeMounts = [
                    {
                      name = "plugin-dir";
                      mountPath = "/csi";
                    }
                    {
                      name = "registration-dir";
                      mountPath = "/registration";
                    }
                  ];
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "50Mi";
                    };
                    requests = {
                      cpu = "100m";
                      memory = "50Mi";
                    };
                  };
                  ports = [
                    {
                      containerPort = 10199;
                      protocol = "TCP";
                      name = "mayastor-node";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "device";
                  hostPath = {
                    path = "/dev";
                    type = "Directory";
                  };
                }
                {
                  name = "sys";
                  hostPath = {
                    path = "/sys";
                    type = "Directory";
                  };
                }
                {
                  name = "run-udev";
                  hostPath = {
                    path = "/run/udev";
                    type = "Directory";
                  };
                }
                {
                  name = "registration-dir";
                  hostPath = {
                    path = "/var/lib/kubelet/plugins_registry/";
                    type = "Directory";
                  };
                }
                {
                  name = "plugin-dir";
                  hostPath = {
                    path = "/var/lib/kubelet/plugins/io.openebs.mayastor/";
                    type = "DirectoryOrCreate";
                  };
                }
                {
                  name = "kubelet-dir";
                  hostPath = {
                    path = "/var/lib/kubelet";
                    type = "Directory";
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.apiRestService
          self.mayastorSa
        ];
      })
    else
      null;

  # --- io-engine DaemonSet (Mayastor data plane — hugepages, privileged) ---
  ioEngineDaemonSet =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-io-engine";
        labels = mayastorLabels // {
          app = "io-engine";
        };
        spec = {
          selector.matchLabels = mayastorSelector "io-engine";
          updateStrategy.type = "OnDelete"; # io-engine requires manual rolling restart
          minReadySeconds = 10;
          template = {
            metadata.labels = mayastorSelector "io-engine" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              hostNetwork = true;
              dnsPolicy = "ClusterFirstWithHostNet";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
                "openebs.io/engine" = "mayastor"; # Only on designated storage nodes
              };
              initContainers = [
                {
                  name = "agent-core-grpc-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "metrics-exporter-io-engine";
                  image = config.mayastor.image.metricsExporter;
                  imagePullPolicy = "IfNotPresent";
                  env = [
                    {
                      name = "MY_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "MY_POD_IP";
                      valueFrom.fieldRef.fieldPath = "status.podIP";
                    }
                  ];
                  ports = [
                    {
                      containerPort = 9502;
                      protocol = "TCP";
                      name = "metrics";
                    }
                  ];
                  args = [
                    "--fmt-style=pretty"
                    "--ansi-colors=true"
                  ];
                }
                {
                  name = "io-engine";
                  image = config.mayastor.image.ioEngine;
                  imagePullPolicy = "IfNotPresent";
                  securityContext.privileged = true;
                  command = [ "io-engine" ];
                  args = [
                    "--grpc-ip=$(MY_POD_IP)"
                    "-N$(MY_NODE_NAME)"
                    "-Rhttps://${name}-agent-core:50051"
                    "-y/var/local/openebs/io-engine/config.yaml"
                    "-l${cpuList}"
                    "-p=${name}-etcd:2379"
                    "--ptpl-dir=/var/local/openebs/io-engine/ptpl/"
                    "--api-versions=v1"
                    "--tgt-crdt=30"
                    "--events-url=nats://${name}-nats:4222"
                    "--ps-retries=300"
                  ];
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "NVMF_TCP_MAX_QPAIRS_PER_CTRL";
                      value = "32";
                    }
                    {
                      name = "NVMF_TCP_MAX_QUEUE_DEPTH";
                      value = "32";
                    }
                    {
                      name = "NVME_TIMEOUT";
                      value = "110s";
                    }
                    {
                      name = "NVME_TIMEOUT_ADMIN";
                      value = "30s";
                    }
                    {
                      name = "NVME_KATO";
                      value = "10s";
                    }
                    {
                      name = "MY_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "MY_POD_IP";
                      valueFrom.fieldRef.fieldPath = "status.podIP";
                    }
                    {
                      name = "NEXUS_NVMF_ANA_ENABLE";
                      value = "1";
                    }
                    {
                      name = "NEXUS_NVMF_RESV_ENABLE";
                      value = "1";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "device";
                      mountPath = "/dev";
                    }
                    {
                      name = "udev";
                      mountPath = "/run/udev";
                    }
                    {
                      name = "dshm";
                      mountPath = "/dev/shm";
                    }
                    {
                      name = "configlocation";
                      mountPath = "/var/local/openebs/io-engine/";
                    }
                    {
                      name = "hugepage";
                      mountPath = "/dev/hugepages";
                    }
                  ];
                  resources = config.mayastor.ioEngine.resources;
                  ports = [
                    {
                      containerPort = 10124;
                      protocol = "TCP";
                      name = "io-engine";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "device";
                  hostPath = {
                    path = "/dev";
                    type = "Directory";
                  };
                }
                {
                  name = "udev";
                  hostPath = {
                    path = "/run/udev";
                    type = "Directory";
                  };
                }
                {
                  name = "dshm";
                  emptyDir = {
                    medium = "Memory";
                    sizeLimit = "1Gi";
                  };
                }
                {
                  name = "hugepage";
                  emptyDir = {
                    medium = "HugePages";
                  };
                }
                {
                  name = "configlocation";
                  hostPath = {
                    path = "/var/local/openebs/io-engine/";
                    type = "DirectoryOrCreate";
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.agentCoreService
          self.etcdService
          self.natsService
        ];
      })
    else
      null;

  # --- io-engine metrics Service ---
  ioEngineMetricsService =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-metrics-exporter-io-engine";
        labels = mayastorLabels // {
          app = "io-engine";
        };
        spec = {
          selector = self.ioEngineDaemonSet.out.selector;
          ports = [
            {
              name = "metrics";
              port = 9502;
              targetPort = 9502;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  # --- agent-ha-node DaemonSet ---
  agentHaNodeDaemonSet =
    if config.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-agent-ha-node";
        labels = mayastorLabels // {
          app = "agent-ha-node";
        };
        spec = {
          selector.matchLabels = mayastorSelector "agent-ha-node";
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          minReadySeconds = 10;
          template = {
            metadata.labels = mayastorSelector "agent-ha-node" // {
              "openebs.io/version" = config.mayastor.version;
            };
            spec = {
              hostNetwork = true;
              dnsPolicy = "ClusterFirstWithHostNet";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              initContainers = [
                {
                  name = "agent-cluster-grpc-probe";
                  image = config.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50052; do date; echo \"Waiting for agent-cluster-grpc...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "agent-ha-node";
                  image = config.mayastor.image.agentHaNode;
                  imagePullPolicy = "IfNotPresent";
                  securityContext.privileged = true;
                  env = [
                    {
                      name = "RUST_LOG";
                      value = "info";
                    }
                    {
                      name = "MY_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "MY_POD_IP";
                      valueFrom.fieldRef.fieldPath = "status.podIP";
                    }
                    {
                      name = "RUST_BACKTRACE";
                      value = "1";
                    }
                  ];
                  args = [
                    "--node-name=$(MY_NODE_NAME)"
                    "--csi-socket=/csi/csi.sock"
                    "--grpc-ip=$(MY_POD_IP)"
                    "--grpc-port=50053"
                    "--cluster-agent=https://${name}-agent-core:50052"
                    "--events-url=nats://${name}-nats:4222"
                    "--ansi-colors=true"
                    "--fmt-style=pretty"
                  ];
                  volumeMounts = [
                    {
                      name = "device";
                      mountPath = "/dev";
                    }
                    {
                      name = "sys";
                      mountPath = "/sys";
                    }
                    {
                      name = "run-udev";
                      mountPath = "/run/udev";
                    }
                    {
                      name = "plugin-dir";
                      mountPath = "/csi";
                    }
                  ];
                  resources = {
                    limits = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                    requests = {
                      cpu = "100m";
                      memory = "64Mi";
                    };
                  };
                  ports = [
                    {
                      containerPort = 50053;
                      protocol = "TCP";
                      name = "ha-node";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "device";
                  hostPath = {
                    path = "/dev";
                    type = "Directory";
                  };
                }
                {
                  name = "sys";
                  hostPath = {
                    path = "/sys";
                    type = "Directory";
                  };
                }
                {
                  name = "run-udev";
                  hostPath = {
                    path = "/run/udev";
                    type = "Directory";
                  };
                }
                {
                  name = "plugin-dir";
                  hostPath = {
                    path = "/var/lib/kubelet/plugins/io.openebs.mayastor/";
                    type = "DirectoryOrCreate";
                  };
                }
              ];
            };
          };
        };
        requires = [
          self.agentCoreService
          self.natsService
        ];
      })
    else
      null;

  # --- Mayastor default StorageClass ---
  mayastorStorageClass =
    if config.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        name = "openebs-single-replica";
        labels = mayastorLabels;
        extra = {
          provisioner = "io.openebs.csi-mayastor";
          volumeBindingMode = "Immediate";
          parameters = {
            ioTimeout = "30";
            protocol = "nvmf";
            repl_count = "1";
          };
        };
      })
    else
      null;

}
// mayastorClusterRoles
