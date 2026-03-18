# Velero backup/disaster recovery package.
#
# Provides server deployment, node-agent DaemonSet for filesystem backups,
# BackupStorageLocation, optional VolumeSnapshotLocation, and scheduled
# backup CRs.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment,
#            DaemonSet (node-agent), ConfigMap (plugins), Secret (credentials),
#            BackupStorageLocation, VolumeSnapshotLocation, Schedule CRs.
#
# main = Deployment (velero server)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "velero/velero";
      tag = "v1.15.2";
      pullPolicy = "IfNotPresent";
    };
    initContainers = [
      {
        name = "velero-plugin-for-aws";
        image = "velero/velero-plugin-for-aws:v1.11.1";
        volumeMounts = [
          {
            name = "plugins";
            mountPath = "/target";
          }
        ];
      }
    ];
    deployNodeAgent = true;
    nodeAgent = {
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "2";
        memory = "8Gi";
      };
    };
    backupStorageLocation = {
      provider = "aws";
      bucket = "velero-backups";
      config = {
        region = "eu-central";
        s3ForcePathStyle = "true";
        s3Url = "";
      };
    };
    credentials = {
      secretName = null;
      secretContents = null;
    };
    schedules = { };
    snapshotLocation = {
      enabled = false;
      provider = "aws";
      config = { };
    };
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "velero";
    "app.kubernetes.io/instance" = name;
  };

  nodeAgentLabels = selectorLabels // {
    "app.kubernetes.io/component" = "node-agent";
  };

  # Whether we create the credentials secret ourselves.
  createSecret = cfg.credentials.secretContents != null;
  credentialSecretName =
    if cfg.credentials.secretName != null then cfg.credentials.secretName else "${name}-credentials";

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    inherit name;
    labels = selectorLabels;
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    inherit name;
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "velero.io" ];
        resources = [
          "backups"
          "backupstoragelocations"
          "deletebackuprequests"
          "downloadrequests"
          "podvolumebackups"
          "podvolumerestores"
          "restoreprogresses"
          "restores"
          "schedules"
          "serverstatusrequests"
          "volumesnapshotlocations"
          "datadownloads"
          "datauploads"
          "backuprepositories"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [
          "namespaces"
          "persistentvolumes"
          "persistentvolumeclaims"
          "pods"
          "secrets"
          "services"
          "configmaps"
          "serviceaccounts"
          "events"
          "pods/log"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        apiGroups = [ "apps" ];
        resources = [
          "deployments"
          "statefulsets"
          "daemonsets"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "batch" ];
        resources = [
          "jobs"
          "cronjobs"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        apiGroups = [ "rbac.authorization.k8s.io" ];
        resources = [
          "clusterroles"
          "clusterrolebindings"
          "roles"
          "rolebindings"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "snapshot.storage.k8s.io" ];
        resources = [
          "volumesnapshots"
          "volumesnapshotcontents"
          "volumesnapshotclasses"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
    ];
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    inherit name;
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # --- Secret (S3 credentials) ---
  secret =
    if createSecret then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = credentialSecretName;
        labels = selectorLabels;
        extra.type = "Opaque";
        stringData = cfg.credentials.secretContents;
      }
    else
      null;

  # --- ConfigMap (optional plugins config) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-plugins";
    labels = selectorLabels;
    data = { };
  };

  # --- Deployment (velero server) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    inherit name;
    labels = selectorLabels;
    spec = {
      replicas = 1;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = selectorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 3600;
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 65534;
            runAsGroup = 65534;
            seccompProfile.type = "RuntimeDefault";
          };
          initContainers = map (ic: {
            inherit (ic) name image volumeMounts;
            imagePullPolicy = cfg.image.pullPolicy;
          }) cfg.initContainers;
          containers = [
            {
              name = "velero";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              command = [ "/velero" ];
              args = [
                "server"
                "--features="
              ];
              env = [
                {
                  name = "VELERO_SCRATCH_DIR";
                  value = "/scratch";
                }
                {
                  name = "VELERO_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
                {
                  name = "LD_LIBRARY_PATH";
                  value = "/plugins";
                }
              ]
              ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
                {
                  name = "AWS_SHARED_CREDENTIALS_FILE";
                  value = "/credentials/cloud";
                }
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8085;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/metrics";
                  port = "metrics";
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 30;
                timeoutSeconds = 5;
                failureThreshold = 5;
                successThreshold = 1;
              };
              readinessProbe = {
                httpGet = {
                  path = "/metrics";
                  port = "metrics";
                  scheme = "HTTP";
                };
                initialDelaySeconds = 10;
                periodSeconds = 10;
                timeoutSeconds = 5;
                failureThreshold = 5;
                successThreshold = 1;
              };
              resources = cfg.resources;
              volumeMounts = [
                {
                  name = "plugins";
                  mountPath = "/plugins";
                }
                {
                  name = "scratch";
                  mountPath = "/scratch";
                }
              ]
              ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
                {
                  name = "cloud-credentials";
                  mountPath = "/credentials";
                  readOnly = true;
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
            }
          ];
          volumes = [
            {
              name = "plugins";
              emptyDir = { };
            }
            {
              name = "scratch";
              emptyDir = { };
            }
          ]
          ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
            {
              name = "cloud-credentials";
              secret.secretName = credentialSecretName;
            }
          ];
        };
      };
    };
  };

  # --- DaemonSet (node-agent) ---
  nodeAgent =
    if cfg.deployNodeAgent then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-node-agent";
        labels = nodeAgentLabels;
        spec = {
          selector.matchLabels = nodeAgentLabels;
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          template = {
            metadata.labels = nodeAgentLabels;
            spec = {
              serviceAccountName = "${self.serviceAccount}";
              securityContext = {
                runAsUser = 0;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "node-agent";
                  image = "${cfg.image.repository}:${cfg.image.tag}";
                  imagePullPolicy = cfg.image.pullPolicy;
                  command = [ "/velero" ];
                  args = [
                    "node-agent"
                    "server"
                  ];
                  env = [
                    {
                      name = "VELERO_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                    {
                      name = "VELERO_SCRATCH_DIR";
                      value = "/scratch";
                    }
                    {
                      name = "NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                  ]
                  ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
                    {
                      name = "AWS_SHARED_CREDENTIALS_FILE";
                      value = "/credentials/cloud";
                    }
                  ];
                  resources = cfg.nodeAgent.resources;
                  volumeMounts = [
                    {
                      name = "host-pods";
                      mountPath = "/host_pods";
                      mountPropagation = "HostToContainer";
                    }
                    {
                      name = "scratch";
                      mountPath = "/scratch";
                    }
                  ]
                  ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
                    {
                      name = "cloud-credentials";
                      mountPath = "/credentials";
                      readOnly = true;
                    }
                  ];
                  securityContext = {
                    privileged = false;
                    capabilities.drop = [ "ALL" ];
                  };
                }
              ];
              volumes = [
                {
                  name = "host-pods";
                  hostPath = {
                    path = "/var/lib/kubelet/pods";
                  };
                }
                {
                  name = "scratch";
                  emptyDir = { };
                }
              ]
              ++ lib.optionals (cfg.credentials.secretName != null || createSecret) [
                {
                  name = "cloud-credentials";
                  secret.secretName = credentialSecretName;
                }
              ];
            };
          };
        };
      }
    else
      null;

  # --- BackupStorageLocation ---
  backupStorageLocation = scope.mkResource {
    apiVersion = "velero.io/v1";
    kind = "BackupStorageLocation";
    name = "${name}-default";
    labels = selectorLabels;
    spec = {
      provider = cfg.backupStorageLocation.provider;
      default = true;
      objectStorage = {
        bucket = cfg.backupStorageLocation.bucket;
      };
      config = lib.filterAttrs (_: v: v != "") cfg.backupStorageLocation.config;
    };
    requires = [ self.deployment ];
  };

  # --- VolumeSnapshotLocation (optional) ---
  volumeSnapshotLocation =
    if cfg.snapshotLocation.enabled then
      scope.mkResource {
        apiVersion = "velero.io/v1";
        kind = "VolumeSnapshotLocation";
        name = "${name}-default";
        labels = selectorLabels;
        spec = {
          provider = cfg.snapshotLocation.provider;
          config = cfg.snapshotLocation.config;
        };
        requires = [ self.deployment ];
      }
    else
      null;

  # --- Schedule CRs ---
  schedules = lib.mapAttrs (
    scheduleName: scheduleCfg:
    scope.mkResource {
      apiVersion = "velero.io/v1";
      kind = "Schedule";
      name = "${name}-${scheduleName}";
      labels = selectorLabels;
      spec = {
        schedule = scheduleCfg.schedule;
        template = scheduleCfg.template or { };
      };
      requires = [
        self.deployment
        self.backupStorageLocation
      ];
    }
  ) cfg.schedules;

  # --- Entry point ---
  main = {
    resource = self.deployment;
    requires = [
      self.serviceAccount
      self.clusterRole
      self.clusterRoleBinding
      self.configmap
      self.backupStorageLocation
    ]
    ++ lib.optional (self.nodeAgent != null) self.nodeAgent
    ++ lib.optional (self.secret != null) self.secret
    ++ lib.optional (self.volumeSnapshotLocation != null) self.volumeSnapshotLocation
    ++ lib.attrValues self.schedules;
  };
}
