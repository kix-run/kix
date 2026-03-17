# Velero package — v2.
#
# Migrated from pkgs-fp/velero/ (v1 fixpoint pattern).
# Source Helm chart: vmware-tanzu/velero
# https://github.com/vmware-tanzu/velero
#
# Velero is a backup/restore/migration tool for Kubernetes clusters.
# It snapshots cluster state and persistent volumes to object storage
# (S3-compatible), enabling disaster recovery and cluster migration.
#
# Resources:
#   - ServiceAccount — identity for velero server and node-agent pods
#   - ClusterRole + ClusterRoleBinding — very broad permissions needed
#     because velero must be able to backup/restore ANY resource type
#   - Deployment — the velero server (controller + API server)
#   - DaemonSet (node-agent) — runs on every node for filesystem-level
#     backups via restic/kopia. Only included when deployNodeAgent=true.
#   - BackupStorageLocation — tells velero where to store backups (S3)
#   - VolumeSnapshotLocation — tells velero where to store volume snapshots
#   - Schedule — automated daily backup schedule
#   - ConfigMap (volume-policies) — rules for which volumes to skip,
#     which to backup via filesystem (by storage class)
#   - Secret (credentials) — AWS/S3 credentials for the storage backend
#
# Design decisions:
#   - `main` is the Deployment because velero doesn't serve user traffic.
#     The Deployment requires everything else — RBAC, storage locations,
#     schedule, credentials, and conditionally the node-agent DaemonSet.
#   - BackupStorageLocation and VolumeSnapshotLocation are velero CRDs
#     (velero.io/v1). They're created as regular resources with `extra`
#     for their non-standard top-level `spec` fields.
#   - The Secret uses stringData with a placeholder — in production this
#     would be replaced by an external secret manager or sealed secret.
#   - Volume policies ConfigMap is generated from the skip/filesystem
#     storage class lists, producing the YAML format velero expects.
#   - Node-agent DaemonSet is gated via requires so it's only in
#     the closure when deployNodeAgent=true.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    image = {
      repository = "velero/velero";
      tag = "v1.15.2";
      pullPolicy = "IfNotPresent";
    };

    # AWS plugin init container image. The init container copies the
    # plugin binary into /target which velero's plugin system picks up.
    pluginImage = {
      repository = "velero/velero-plugin-for-aws";
      tag = "v1.9.0";
      pullPolicy = "IfNotPresent";
    };

    # kubectl image used by node-agent for pre-stop hooks and health
    # checks that need to talk to the K8s API.
    kubectlImage = {
      repository = "bitnami/kubectl";
      tag = "1.33.4";
    };

    # S3-compatible object storage configuration. All fields are
    # required for a functional deployment — defaults are empty
    # placeholders that must be overridden.
    s3 = {
      url = "";
      publicUrl = "";
      region = "eu-central";
      bucket = "";
      forcePathStyle = true;
    };

    # Backup schedule configuration.
    # ttl: how long to retain backups (720h = 30 days).
    # snapshotVolumes: take CSI volume snapshots.
    # snapshotMoveData: move snapshot data to object storage (important
    # for cross-cluster restores where the original PV doesn't exist).
    schedule = {
      cron = "30 03 * * *";
      ttl = "720h0m0s";
      snapshotVolumes = true;
      snapshotMoveData = true;
    };

    # Resource requests/limits for the velero server container.
    # Memory limit at 8Gi is high but necessary — velero can spike
    # during large backup operations when it's serializing many
    # resources simultaneously.
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

    # Storage classes whose PVs should be completely skipped during
    # backup (e.g., ephemeral local storage that doesn't need backup).
    skipBackupStorageClasses = [ ];

    # Storage classes whose PVs should be backed up via filesystem
    # (restic/kopia) instead of CSI snapshots. Useful for storage
    # backends that don't support CSI snapshots.
    filesystemBackupStorageClasses = [
      "mayastor-etcd-localpv"
      "mayastor-loki-localpv"
    ];

    # Whether to deploy the node-agent DaemonSet. Required for
    # filesystem-level backups (restic/kopia). Disable if you only
    # use CSI volume snapshots.
    deployNodeAgent = true;
  };

  # --- Derived values ---
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";
  pluginImageRef = "${cfg.pluginImage.repository}:${cfg.pluginImage.tag}";

  # --- Labels ---
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "velero";
  };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    };

  # Component-specific labels for multi-component packages.
  # velero has two workloads: server (Deployment) and node-agent (DaemonSet).
  withComponent =
    component:
    selectorLabels
    // {
      "app.kubernetes.io/component" = component;
    };
  allLabelsWithComponent =
    component:
    allLabels
    // {
      "app.kubernetes.io/component" = component;
    };

  # --- Volume policies YAML generation ---
  # Velero's volume policy ConfigMap expects a YAML document with
  # version and volumePolicies list. Each policy has conditions
  # (matched by storageClass) and an action (skip or fs-backup).
  #
  # We generate this from the skipBackupStorageClasses and
  # filesystemBackupStorageClasses arguments so operators only
  # need to specify storage class names, not write raw YAML.
  skipPolicies = map (sc: {
    conditions.storageClass = [ sc ];
    action.type = "skip";
  }) cfg.skipBackupStorageClasses;

  fsPolicies = map (sc: {
    conditions.storageClass = [ sc ];
    action.type = "fs-backup";
  }) cfg.filesystemBackupStorageClasses;

  volumePoliciesYaml = builtins.toJSON {
    version = "v1";
    volumePolicies = skipPolicies ++ fsPolicies;
  };

in self: {

  # ── Secret (credentials) ──────────────────────────────────────────
  #
  # Placeholder for AWS/S3 credentials. In production, this would be
  # managed by external-secrets-operator or sealed-secrets. The format
  # matches what the velero-plugin-for-aws expects:
  #   [default]
  #   aws_access_key_id=<key>
  #   aws_secret_access_key=<secret>

  credentialsSecret = scope.mkResource {
    apiVersion = "v1";
    kind = "Secret";
    name = "${scope.instanceName}-velero-credentials";
    labels = allLabels;
    extra.type = "Opaque";
    stringData = {
      cloud = ''
        [default]
        aws_access_key_id=CHANGE_ME
        aws_secret_access_key=CHANGE_ME
      '';
    };
  };

  # ── RBAC ──────────────────────────────────────────────────────────
  #
  # Velero needs extremely broad permissions because it must be able
  # to backup and restore ANY resource in the cluster. This includes
  # all core resources, apps workloads, batch jobs, CRDs, and the
  # velero.io CRDs themselves. The breadth of these rules is
  # intentional and matches the upstream Helm chart.
  #
  # YAML ref direction:   binding -> role, binding -> SA
  # Semantic dep direction: SA -> binding -> role

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-velero-server";
    labels = allLabels;
    extra.rules = [
      # Velero CRDs: full control over backup/restore/schedule resources
      {
        apiGroups = [ "velero.io" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # Core API: full access to pods, services, configmaps, secrets,
      # PVs, PVCs, namespaces, events, etc. Required for backup/restore.
      {
        apiGroups = [ "" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # Apps: deployments, statefulsets, daemonsets, replicasets.
      # Required for backup/restore of workloads.
      {
        apiGroups = [ "apps" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # Batch: jobs, cronjobs. Required for backup/restore.
      {
        apiGroups = [ "batch" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # Extensions: legacy API group, kept for compatibility with older
      # resources that may still exist in clusters.
      {
        apiGroups = [ "extensions" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # CSI volume snapshots: velero uses these for volume backup when
      # CSI snapshots are enabled (snapshotVolumes=true).
      {
        apiGroups = [ "snapshot.storage.k8s.io" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      # CRDs: velero needs to discover and backup custom resources.
      # Also needed for velero's own CRD management during install.
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [ "*" ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-velero-server";
    labels = allLabels;
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

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-velero";
    labels = allLabels;
  };

  # ── BackupStorageLocation ─────────────────────────────────────────
  #
  # Tells velero where to store backup data. Uses the velero-plugin-for-aws
  # which supports any S3-compatible storage (AWS S3, MinIO, Ceph RGW, etc).
  # The credential field points to the Secret we create above.
  #
  # This is a velero CRD (velero.io/v1), not a standard K8s resource.
  # All fields are under `spec`, passed via `extra` since they are
  # non-standard top-level fields.

  backupStorageLocation = scope.mkResource {
    apiVersion = "velero.io/v1";
    kind = "BackupStorageLocation";
    name = "${scope.instanceName}-default";
    labels = allLabels;
    extra.spec = {
      provider = "velero.io/aws";
      default = true;
      credential = {
        name = "${self.credentialsSecret}";
        key = "cloud";
      };
      config = {
        s3Url = cfg.s3.url;
        publicUrl = cfg.s3.publicUrl;
        region = cfg.s3.region;
        s3ForcePathStyle = if cfg.s3.forcePathStyle then "true" else "false";
      };
      objectStorage = {
        bucket = cfg.s3.bucket;
      };
    };
  };

  # ── VolumeSnapshotLocation ────────────────────────────────────────
  #
  # Tells velero where to store CSI volume snapshots. Separate from
  # BackupStorageLocation because snapshots may go to a different
  # region or provider than the backup metadata.

  volumeSnapshotLocation = scope.mkResource {
    apiVersion = "velero.io/v1";
    kind = "VolumeSnapshotLocation";
    name = "${scope.instanceName}-default";
    labels = allLabels;
    extra.spec = {
      provider = "velero.io/aws";
      credential = {
        name = "${self.credentialsSecret}";
        key = "cloud";
      };
      config = {
        region = cfg.s3.region;
      };
    };
  };

  # ── ConfigMap (volume policies) ───────────────────────────────────
  #
  # Velero reads volume policies from a ConfigMap to decide how to
  # handle PVs during backup. Policies are matched by storage class:
  #   - "skip": don't backup this volume at all (ephemeral data)
  #   - "fs-backup": use filesystem backup (restic/kopia) instead of
  #     CSI snapshots (for storage backends without snapshot support)
  #
  # The YAML is generated from skipBackupStorageClasses and
  # filesystemBackupStorageClasses args — see volumePoliciesYaml in let block.

  volumePoliciesConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-velero-volume-policies";
    labels = allLabels;
    data = {
      # Key must be "policies" (no extension) — velero expects this exact key name
      # when referenced via resourcePolicy in the Schedule template.
      policies = volumePoliciesYaml;
    };
  };

  # ── Schedule ──────────────────────────────────────────────────────
  #
  # Automated daily backup at 03:30 UTC (configurable via schedule.cron).
  # The template section mirrors what you'd pass to `velero backup create`.
  #
  # Key settings:
  #   - ttl: backup retention period (default 30 days)
  #   - snapshotVolumes: take CSI snapshots of PVs
  #   - snapshotMoveData: copy snapshot data to object storage
  #     (critical for cross-cluster restore scenarios)
  #   - storageLocation/volumeSnapshotLocations: reference our BSL/VSL
  #
  # This is a velero CRD — spec fields go in `extra.spec`.

  dailySchedule = scope.mkResource {
    apiVersion = "velero.io/v1";
    kind = "Schedule";
    name = "${scope.instanceName}-daily-cluster-backup";
    labels = allLabels;
    extra.spec = {
      schedule = cfg.schedule.cron;
      template = {
        ttl = cfg.schedule.ttl;
        snapshotVolumes = cfg.schedule.snapshotVolumes;
        snapshotMoveData = cfg.schedule.snapshotMoveData;
        storageLocation = "${self.backupStorageLocation}";
        volumeSnapshotLocations = [ "${self.volumeSnapshotLocation}" ];
        # Include cluster-scoped resources (namespaces, CRDs, ClusterRoles, etc.)
        includeClusterResources = true;
        # Timeouts for CSI snapshot operations and item operations
        csiSnapshotTimeout = "10m";
        itemOperationTimeout = "4h";
        # Don't default to filesystem backup — use CSI snapshots where possible
        defaultVolumesToFsBackup = false;
        # hooks: empty but required by velero to avoid nil pointer
        hooks = { };
        # Exclude PVCs labeled with velero.io/exclude-from-backup=true
        orLabelSelectors = [
          {
            matchExpressions = [
              {
                key = "velero.io/exclude-from-backup";
                operator = "NotIn";
                values = [ "true" ];
              }
            ];
          }
        ];
        # Reference the volume policies ConfigMap — this is how velero
        # knows to skip/fs-backup certain storage classes.
        resourcePolicy = {
          kind = "configmap";
          name = "${self.volumePoliciesConfigMap}";
        };
        metadata = {
          labels = {
            schedule = "daily-cluster-backup";
            schedule_version = "10";
          };
        };
      };
    };
  };

  # ── Deployment (velero server) ────────────────────────────────────
  #
  # The main velero server process. Runs as a single-replica Deployment
  # (scaling velero server horizontally is not supported — it uses
  # leader election internally but the Helm chart defaults to 1 replica).
  #
  # The init container loads the AWS plugin: it copies the plugin binary
  # from the plugin image into a shared /target volume. Velero discovers
  # plugins in /plugins at startup.
  #
  # Key volume mounts:
  #   - plugins: shared emptyDir between init container and main container
  #   - cloud-credentials: the S3 credentials secret mounted as a file
  #   - scratch: temporary workspace for backup/restore operations

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-velero";
    labels = allLabelsWithComponent "server";
    requires = [
      self.serviceAccount
      self.credentialsSecret
      self.backupStorageLocation
      self.volumeSnapshotLocation
      self.dailySchedule
      self.volumePoliciesConfigMap
    ];
    spec = {
      replicas = 1;
      selector.matchLabels = withComponent "server";
      template = {
        metadata.labels = allLabelsWithComponent "server";
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          initContainers = [
            {
              # AWS plugin init container: copies the plugin binary
              # into /target, which is mounted as /plugins in the main
              # container. This is the standard velero plugin loading
              # pattern — each plugin runs as an init container that
              # populates a shared volume.
              name = "velero-plugin-for-aws";
              image = pluginImageRef;
              imagePullPolicy = cfg.pluginImage.pullPolicy;
              volumeMounts = [
                {
                  name = "plugins";
                  mountPath = "/target";
                }
              ];
            }
          ];
          containers = [
            {
              name = "velero";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              inherit (cfg) resources;
              command = [ "/velero" ];
              args = [
                "server"
                "--uploader-type=kopia"
                # Enable CSI volume snapshot support — without this flag,
                # velero won't take CSI snapshots even if snapshotVolumes=true.
                "--features=EnableCSI"
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8085;
                  protocol = "TCP";
                }
              ];
              volumeMounts = [
                {
                  name = "plugins";
                  mountPath = "/plugins";
                }
                {
                  name = "cloud-credentials";
                  mountPath = "/credentials";
                  readOnly = true;
                }
                {
                  name = "scratch";
                  mountPath = "/scratch";
                }
              ];
              env = [
                {
                  name = "VELERO_SCRATCH_DIR";
                  value = "/scratch";
                }
                {
                  name = "AWS_SHARED_CREDENTIALS_FILE";
                  value = "/credentials/cloud";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "plugins";
              emptyDir = { };
            }
            {
              name = "cloud-credentials";
              secret.secretName = "${self.credentialsSecret}";
            }
            {
              name = "scratch";
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  # ── DaemonSet (node-agent) ────────────────────────────────────────
  #
  # Runs velero's node-agent on every node in the cluster. The node-agent
  # is responsible for filesystem-level backups using kopia (or restic).
  # It needs to run on every node because it accesses PV data via
  # hostPath mounts — the backup must happen on the node where the PV
  # is attached.
  #
  # This resource is always defined but only included in the closure
  # when deployNodeAgent=true (gated via requires on main).

  nodeAgent = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "DaemonSet";
    name = "${scope.instanceName}-node-agent";
    labels = allLabelsWithComponent "node-agent";
    requires = [
      self.serviceAccount
      self.credentialsSecret
    ];
    spec = {
      selector.matchLabels = withComponent "node-agent";
      template = {
        metadata.labels = allLabelsWithComponent "node-agent";
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          containers = [
            {
              name = "node-agent";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              command = [ "/velero" ];
              args = [
                "node-agent"
                "server"
                "--uploader-type=kopia"
              ];
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "64Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "2Gi";
                };
              };
              env = [
                {
                  name = "VELERO_SCRATCH_DIR";
                  value = "/scratch";
                }
                {
                  name = "AWS_SHARED_CREDENTIALS_FILE";
                  value = "/credentials/cloud";
                }
                # NODE_NAME is used by velero to associate backups
                # with the correct node.
                {
                  name = "NODE_NAME";
                  valueFrom.fieldRef.fieldPath = "spec.nodeName";
                }
              ];
              volumeMounts = [
                {
                  name = "cloud-credentials";
                  mountPath = "/credentials";
                  readOnly = true;
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
              securityContext = {
                privileged = false;
                runAsUser = 0;
              };
            }
          ];
          volumes = [
            {
              name = "cloud-credentials";
              secret.secretName = "${self.credentialsSecret}";
            }
            {
              # hostPath mount to access pod volumes on the node.
              # The node-agent reads PV data from here during
              # filesystem backups.
              name = "host-pods";
              hostPath = {
                path = "/var/lib/kubelet/pods";
              };
            }
            {
              name = "scratch";
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  # ── Main: the public interface ────────────────────────────────────
  #
  # Velero doesn't serve user traffic — it's a controller that talks
  # to the K8s API and object storage. The Deployment is the primary
  # resource. All supporting resources (RBAC, storage locations,
  # schedule, credentials, volume policies) are pulled in via requires.
  #
  # The node-agent DaemonSet is conditionally included based on
  # deployNodeAgent — when false, only CSI snapshot-based backups
  # are available (no filesystem backups).

  main = {
    resource = self.deployment;
    requires =
      [
        self.serviceAccount
        self.credentialsSecret
        self.backupStorageLocation
        self.volumeSnapshotLocation
        self.dailySchedule
        self.volumePoliciesConfigMap
      ]
      ++ lib.optional cfg.deployNodeAgent self.nodeAgent;
  };
}
