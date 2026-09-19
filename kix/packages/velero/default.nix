# Velero backup/disaster recovery package.
#
# Provides server deployment, node-agent DaemonSet for filesystem backups,
# BackupStorageLocation, optional VolumeSnapshotLocation, and scheduled
# backup CRs.
#
# Resources: CustomResourceDefinitions (velero.io v1 + v2alpha1, vendored from
#            upstream v1.15.2), ServiceAccount, ClusterRoleBinding, Role,
#            RoleBinding, Deployment, DaemonSet (node-agent), ConfigMap
#            (volume-policies), Service, BackupStorageLocation,
#            VolumeSnapshotLocation, Schedule CRs.
#
# root = Deployment (velero server)
#
# Exposes via DI:
#   velero.out.withBackup    — transformer: include resource in backups
#   velero.out.withoutBackup — transformer: exclude resource from backups

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "velero";
    "app.kubernetes.io/instance" = name;
  };

in
{
  meta = {
    version = "v1.15.2";
    # The velero server has no leader election and a second one would race
    # the first over backups, so one replica is the ceiling it can honour.
    availability.max = "pod";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "velero/velero";
        tag = "v1.15.2";
        pullPolicy = "IfNotPresent";
      };
    };
    initContainers = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [
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
    };
    # Server args configuration
    uploaderType = lib.mkOption {
      type = lib.types.str;
      default = "kopia";
    };
    features = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    keepLatestMaintenanceJobs = lib.mkOption {
      type = lib.types.int;
      default = 3;
    };
    deployNodeAgent = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    nodeAgent = lib.mkOption {
      type = lib.types.anything;
      default = {
        resources = { };
      };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "2";
          memory = "8Gi";
        };
      };
    };
    clusterRoleName = lib.mkOption {
      type = lib.types.str;
      default = "cluster-admin";
    };
    backupStorageLocation = lib.mkOption {
      type = lib.types.anything;
      default = {
        provider = "velero.io/aws";
        bucket = "velero-backups";
        config = {
          region = "eu-central";
          s3ForcePathStyle = "true";
          s3Url = "";
        };
      };
    };
    credentials = lib.mkOption {
      type = lib.types.anything;
      default = {
        secretName = null;
        secretContents = null;
      };
    };
    volumePolicies = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    };
    schedules = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    snapshotLocation = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        provider = "velero.io/aws";
        config = { };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      objectStorage ? null,
    }:
    let
      # S3 endpoint: explicit config > objectStorage DI dep
      effectiveS3Url =
        if config.backupStorageLocation.config.s3Url or "" != "" then
          config.backupStorageLocation.config.s3Url
        else if objectStorage != null then
          objectStorage.out.endpoint
        else
          "";

      effectivePublicUrl =
        if config.backupStorageLocation.config.publicUrl or "" != "" then
          config.backupStorageLocation.config.publicUrl
        else
          effectiveS3Url;

      effectiveS3ForcePathStyle =
        if config.backupStorageLocation.config.s3ForcePathStyle or "" != "" then
          config.backupStorageLocation.config.s3ForcePathStyle
        else if objectStorage != null then
          objectStorage.out.s3ForcePathStyle or "false"
        else
          "false";

      # Whether we create the credentials secret ourselves.
      createSecret = config.credentials.secretContents != null;
      credentialSecretName =
        if config.credentials.secretName != null then
          config.credentials.secretName
        else
          "${name}-credentials";

      hasCredentials = config.credentials.secretName != null || createSecret;

      # Build server args from config
      serverArgs = [
        "server"
      ]
      ++ lib.optional (config.uploaderType != null) "--uploader-type=${config.uploaderType}"
      ++ lib.optional (config.features != "") "--features=${config.features}"
      ++ lib.optional (
        config.keepLatestMaintenanceJobs != null
      ) "--keep-latest-maintenance-jobs=${toString config.keepLatestMaintenanceJobs}";

      # Build node-agent args from config
      nodeAgentArgs = [
        "node-agent"
        "server"
      ]
      ++ lib.optional (config.features != "") "--features=${config.features}";

      # Credential env vars shared by server and node-agent
      credentialEnvVars = lib.optionals hasCredentials [
        {
          name = "ALIBABA_CLOUD_CREDENTIALS_FILE";
          value = "/credentials/cloud";
        }
        {
          name = "AWS_SHARED_CREDENTIALS_FILE";
          value = "/credentials/cloud";
        }
        {
          name = "AZURE_CREDENTIALS_FILE";
          value = "/credentials/cloud";
        }
        {
          name = "GOOGLE_APPLICATION_CREDENTIALS";
          value = "/credentials/cloud";
        }
      ];

      # --- Schedule CRs (built in let so they can be spread into self) ---
      scheduleResources = lib.mapAttrs (
        scheduleName: scheduleCfg:
        scope.mkResource {
          apiVersion = "velero.io/v1";
          kind = "Schedule";
          name = scheduleName;
          labels = selectorLabels;
          spec = {
            schedule = scheduleCfg.schedule;
            template = scheduleCfg.template or { };
          }
          // lib.optionalAttrs (scheduleCfg ? skipImmediately) {
            skipImmediately = scheduleCfg.skipImmediately;
          };
          # A Schedule cannot be applied before the API server serves the kind.
          requires = [ self.crds.schedules ];
        }
      ) config.schedules;

    in
    scheduleResources
    // {

      # --- CustomResourceDefinitions ---
      # Vendored from upstream velero v1.15.2:
      #   config/crd/v1/bases/velero.io_<plural>.yaml          (group v1)
      #   config/crd/v2alpha1/bases/velero.io_<plural>.yaml    (group v2alpha1)
      # The server and the node-agent both refuse to start until every kind
      # they watch is served, so they require these.
      crds =
        let
          vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
        in
        {
          backupRepositories = scope.mkCRD { spec = vendored "backuprepositories.velero.io.json"; };
          backups = scope.mkCRD { spec = vendored "backups.velero.io.json"; };
          backupStorageLocations = scope.mkCRD { spec = vendored "backupstoragelocations.velero.io.json"; };
          dataDownloads = scope.mkCRD { spec = vendored "datadownloads.velero.io.json"; };
          dataUploads = scope.mkCRD { spec = vendored "datauploads.velero.io.json"; };
          deleteBackupRequests = scope.mkCRD { spec = vendored "deletebackuprequests.velero.io.json"; };
          downloadRequests = scope.mkCRD { spec = vendored "downloadrequests.velero.io.json"; };
          podVolumeBackups = scope.mkCRD { spec = vendored "podvolumebackups.velero.io.json"; };
          podVolumeRestores = scope.mkCRD { spec = vendored "podvolumerestores.velero.io.json"; };
          restores = scope.mkCRD { spec = vendored "restores.velero.io.json"; };
          schedules = scope.mkCRD { spec = vendored "schedules.velero.io.json"; };
          serverStatusRequests = scope.mkCRD { spec = vendored "serverstatusrequests.velero.io.json"; };
          volumeSnapshotLocations = scope.mkCRD { spec = vendored "volumesnapshotlocations.velero.io.json"; };
        };

      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-server";
        labels = selectorLabels;
        extra.automountServiceAccountToken = true;
      };

      # --- ClusterRoleBinding ---
      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "${name}-server";
        labels = selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = config.clusterRoleName;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "${name}-server";
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      # --- Role (namespace-level permissions) ---
      role = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "${name}-server";
        labels = selectorLabels;
        extra.rules = [
          {
            apiGroups = [ "*" ];
            resources = [ "*" ];
            verbs = [ "*" ];
          }
        ];
      };

      # --- RoleBinding ---
      roleBinding = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "${name}-server";
        labels = selectorLabels;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "${name}-server";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "${name}-server";
              namespace = scope.namespaceName;
            }
          ];
        };
      };

      # --- Secret (S3 credentials) ---
      # kix-managed (mkSecret) from secretContents, a reference to a Secret
      # the operator provides (mkSecretRef) from secretName, or nothing:
      # a reference emitted with no credentials configured is an import
      # marker for a Secret nobody creates, and a deploy waits on it until
      # its timeout.
      secret =
        if createSecret then
          scope.mkSecret {
            name = credentialSecretName;
            labels = selectorLabels;
            stringData = config.credentials.secretContents;
          }
        else if config.credentials.secretName != null then
          scope.mkSecretRef {
            name = credentialSecretName;
            keys = [ ];
          }
        else
          null;

      # --- ConfigMap (volume policies) ---
      configmap =
        if config.volumePolicies != null then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-volume-policies";
            labels = selectorLabels;
            data = {
              policies = config.volumePolicies;
            };
          }
        else
          null;

      # --- Service ---
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        labels = selectorLabels;
        spec = {
          type = "ClusterIP";
          ports = [
            {
              name = "http-monitoring";
              port = 8085;
              protocol = "TCP";
              targetPort = "http-monitoring";
            }
          ];
          selector = selectorLabels // {
            name = "velero";
          };
        };
      };

      # --- Deployment (velero server) ---
      deployment = scope.mkDeployment {
        inherit name;
        labels = selectorLabels // {
          component = "velero";
        };
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          # The node-agent pods carry selectorLabels too, so a bare
          # selectorLabels selector would also claim them. name=velero is
          # what tells the two pod sets apart (the Service selector agrees).
          selector.matchLabels = selectorLabels // {
            name = "velero";
          };
          template = {
            metadata = {
              labels = selectorLabels // {
                name = "velero";
              };
              annotations = {
                "prometheus.io/path" = "/metrics";
                "prometheus.io/port" = "8085";
                "prometheus.io/scrape" = "true";
              };
            };
            spec = {
              serviceAccount = self.serviceAccount;
              automountServiceAccountToken = true;
              terminationGracePeriodSeconds = 3600;
              initContainers = map (ic: {
                inherit (ic) name image volumeMounts;
                imagePullPolicy = config.image.pullPolicy;
              }) config.initContainers;
              containers = [
                {
                  name = "velero";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/velero" ];
                  args = serverArgs;
                  env = credentialEnvVars ++ [
                    {
                      name = "LD_LIBRARY_PATH";
                      value = "/plugins";
                    }
                    {
                      name = "VELERO_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                    {
                      name = "VELERO_SCRATCH_DIR";
                      value = "/scratch";
                    }
                  ];
                  ports = [
                    {
                      name = "http-monitoring";
                      containerPort = 8085;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = "http-monitoring";
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
                      port = "http-monitoring";
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 30;
                    timeoutSeconds = 5;
                    failureThreshold = 5;
                    successThreshold = 1;
                  };
                  resources = config.resources;
                  volumeMounts =
                    lib.optionals hasCredentials [
                      {
                        name = "cloud-credentials";
                        mountPath = "/credentials";
                      }
                    ]
                    ++ [
                      {
                        name = "plugins";
                        mountPath = "/plugins";
                      }
                      {
                        name = "scratch";
                        mountPath = "/scratch";
                      }
                    ];
                }
              ];
              volumes =
                lib.optionals hasCredentials [
                  {
                    name = "cloud-credentials";
                    secret = {
                      secretName = self.secret.out.name;
                      defaultMode = 420;
                    };
                  }
                ]
                ++ [
                  {
                    name = "plugins";
                    emptyDir = { };
                  }
                  {
                    name = "scratch";
                    emptyDir = { };
                  }
                ];
            };
          };
        };
        requires = builtins.attrValues self.crds;
      };

      # --- DaemonSet (node-agent) ---
      nodeAgent =
        if config.deployNodeAgent then
          scope.mkDaemonSet {
            name = "node-agent";
            labels = selectorLabels;
            spec = {
              selector.matchLabels = {
                name = "node-agent";
              };
              updateStrategy = {
                type = "RollingUpdate";
                rollingUpdate.maxUnavailable = 1;
              };
              template = {
                metadata = {
                  labels = selectorLabels // {
                    name = "node-agent";
                    role = "node-agent";
                  };
                  annotations = {
                    "prometheus.io/path" = "/metrics";
                    "prometheus.io/port" = "8085";
                    "prometheus.io/scrape" = "true";
                  };
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  automountServiceAccountToken = true;
                  securityContext = {
                    runAsUser = 0;
                  };
                  containers = [
                    (
                      {
                        name = "node-agent";
                        image = "${config.image.repository}:${config.image.tag}";
                        imagePullPolicy = config.image.pullPolicy;
                        command = [ "/velero" ];
                        args = nodeAgentArgs;
                        env = credentialEnvVars ++ [
                          {
                            name = "NODE_NAME";
                            valueFrom.fieldRef.fieldPath = "spec.nodeName";
                          }
                          {
                            name = "VELERO_NAMESPACE";
                            valueFrom.fieldRef.fieldPath = "metadata.namespace";
                          }
                          {
                            name = "VELERO_SCRATCH_DIR";
                            value = "/scratch";
                          }
                        ];
                        ports = [
                          {
                            name = "http-monitoring";
                            containerPort = 8085;
                            protocol = "TCP";
                          }
                        ];
                        volumeMounts =
                          lib.optionals hasCredentials [
                            {
                              name = "cloud-credentials";
                              mountPath = "/credentials";
                            }
                          ]
                          ++ [
                            {
                              name = "host-plugins";
                              mountPath = "/host_plugins";
                              mountPropagation = "HostToContainer";
                            }
                            {
                              name = "host-pods";
                              mountPath = "/host_pods";
                              mountPropagation = "HostToContainer";
                            }
                            {
                              name = "scratch";
                              mountPath = "/scratch";
                            }
                          ];
                      }
                      // lib.optionalAttrs (config.nodeAgent.resources != { }) {
                        resources = config.nodeAgent.resources;
                      }
                    )
                  ];
                  volumes =
                    lib.optionals hasCredentials [
                      {
                        name = "cloud-credentials";
                        secret.secretName = self.secret.out.name;
                      }
                    ]
                    ++ [
                      {
                        name = "host-plugins";
                        hostPath.path = "/var/lib/kubelet/plugins";
                      }
                      {
                        name = "host-pods";
                        hostPath.path = "/var/lib/kubelet/pods";
                      }
                      {
                        name = "scratch";
                        emptyDir = { };
                      }
                    ];
                };
              };
            };
            requires = builtins.attrValues self.crds;
          }
        else
          null;

      # --- BackupStorageLocation ---
      backupStorageLocation = scope.mkResource {
        apiVersion = "velero.io/v1";
        kind = "BackupStorageLocation";
        name = "default";
        labels = selectorLabels;
        spec = {
          provider = config.backupStorageLocation.provider;
          default = true;
          accessMode = "ReadWrite";
          objectStorage = {
            bucket = config.backupStorageLocation.bucket;
          };
          config = lib.filterAttrs (_: v: v != "") (
            config.backupStorageLocation.config
            // {
              s3Url = effectiveS3Url;
              publicUrl = effectivePublicUrl;
              s3ForcePathStyle = effectiveS3ForcePathStyle;
            }
          );
        }
        // lib.optionalAttrs hasCredentials {
          credential = {
            key = "cloud";
            name = credentialSecretName;
          };
        };
        requires = [ self.deployment ];
      };

      # --- VolumeSnapshotLocation (optional) ---
      volumeSnapshotLocation =
        if config.snapshotLocation.enabled then
          scope.mkResource {
            apiVersion = "velero.io/v1";
            kind = "VolumeSnapshotLocation";
            name = "default";
            labels = selectorLabels;
            spec = {
              provider = config.snapshotLocation.provider;
              config = config.snapshotLocation.config;
            }
            // lib.optionalAttrs hasCredentials {
              credential = {
                key = "cloud";
                name = credentialSecretName;
              };
            };
            requires = [ self.deployment ];
          }
        else
          null;

      # --- Entry point ---
      root = {
        resource = self.deployment;
        requires = [
          self.serviceAccount
          self.clusterRoleBinding
          self.role
          self.roleBinding
          self.service
          self.backupStorageLocation
        ]
        ++ lib.optional (self.configmap != null) self.configmap
        ++ lib.optional (self.nodeAgent != null) self.nodeAgent
        ++ lib.optional (self.secret != null) self.secret
        ++ lib.optional (self.volumeSnapshotLocation != null) self.volumeSnapshotLocation
        ++ (builtins.attrValues self.crds)
        ++ (lib.attrValues scheduleResources);

        # Package-level out extensions — exposed via DI as velero.out.*
        out = {
          # Transformer: include a resource in velero backups.
          # Pipe-friendly: `scope.mkResource ({ ... } |> velero.out.withBackup)`
          withBackup =
            args:
            args
            // {
              annotations = (args.annotations or { }) // {
                "velero.io/exclude-from-backup" = "false";
              };
            };

          # Transformer: exclude a resource from velero backups.
          withoutBackup =
            args:
            args
            // {
              annotations = (args.annotations or { }) // {
                "velero.io/exclude-from-backup" = "true";
              };
            };
        };
      };
    };
}
