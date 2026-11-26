# Velero CRDs, RBAC, server Deployment, node-agent DaemonSet, ConfigMaps, and
# operand network policies.

{
  self,
  config,
  scope,
  lib,
  kix,
  cloudCredentials,
  repositoryPassword ? null,
  objectStorage ? null,
  cloudIdentity ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    metricsPort
    componentLabels
    dataPathLabels
    urlPort
    renderPolicy
    withDataPathLabels
    readCloudCredentials
    ;

  creds = readCloudCredentials { inherit cloudCredentials config objectStorage; };

  # The pod labels and credential egress the cloud identity's mechanism
  # needs. The workload builders add both to the server and node-agent. The
  # ConfigMaps give the labels to the pods Velero launches, and
  # dataPathEgress gives them the egress.
  identityMetadata = kix.cloudIdentity.annotationsFor {
    inherit scope;
    inherit (creds) identity;
    provider = cloudIdentity;
  };
  identityLabels = identityMetadata.podLabels;

  # Velero reads the repository key only from this Secret, by name
  # (pkg/repository/keys). Without it, Velero creates the Secret with
  # a key compiled into every Velero binary.
  repoSecretName = "velero-repo-credentials";
  repoPassword =
    let
      checked = kix.contracts.secret.helpers.use {
        inherit scope;
        arg = "repositoryPassword";
        dep = repositoryPassword;
        keys = [ "repository-password" ];
      };
    in
    if repositoryPassword == null then
      if config.nodeAgent.enabled then
        scope.fail {
          dependency = "repositoryPassword";
          message = "node-agent is on and no repositoryPassword dependency resolved, so Velero would encrypt the kopia repositories with the key compiled into every Velero binary.";
          fix = "Add a secret or secret-ref instance named ${repoSecretName} in ${ns} with key repository-password and alias repositoryPassword, or set nodeAgent.enabled = false.";
        }
      else
        null
    else if checked.out.name != repoSecretName then
      scope.fail {
        dependency = "repositoryPassword";
        message = "deps.repositoryPassword resolved to secret \"${checked.out.name}\", but Velero reads the repository key only from a Secret named ${repoSecretName} in ${ns}.";
        fix = "Rename that instance.";
      }
    else
      checked;

  bsl = config.backupStorageLocation;

  # Ports opened outside the cluster: the store on the port of `s3Url`
  # (443 when unset, the AWS endpoints), and HTTPS for a snapshot
  # location's cloud API. An in-cluster store wired as `objectStorage`
  # is opened by the location's operand policy instead.
  externalPorts = lib.unique (
    lib.optional (objectStorage == null) (if bsl.config ? s3Url then urlPort bsl.config.s3Url else 443)
    ++ lib.optional (config.volumeSnapshotLocation != null) 443
  );

  credentialFile = creds.file;

  # Kubernetes resolves a secretKeyRef when a container starts, so a
  # changed key pair reaches the server and node-agent only when they
  # restart. The pods they launch start with the current one.
  credentialEnv =
    if credentialFile then
      lib.genAttrs [
        "AWS_SHARED_CREDENTIALS_FILE"
        "AZURE_CREDENTIALS_FILE"
        "GOOGLE_APPLICATION_CREDENTIALS"
        "ALIBABA_CLOUD_CREDENTIALS_FILE"
      ] (_: "/credentials/cloud")
    else
      lib.genAttrs creds.envKeys creds.dep.out.keyRef;

  # The root filesystem is read-only. kopia keeps its repository config
  # and cache under $HOME, so HOME points at the /scratch emptyDir;
  # Velero writes temp files to /tmp. The pods Velero launches copy
  # this env and these volumes from the server and node-agent. With a
  # cloud identity no credential variable is set, and each SDK finds the
  # credentials the cloud's webhook or agent gives the pod.
  ownedEnv =
    extra:
    lib.optional (creds.identity == null) {
      vars = credentialEnv;
      from =
        if credentialFile then
          "the cloudCredentials dependency, mounted at /credentials/cloud"
        else
          "the cloudCredentials dependency's key pair";
      fix =
        if credentialFile then
          "Remove it, and put the credentials in that Secret's `cloud` key."
        else
          "Remove it, and put the key pair in the cloudCredentials Secret.";
    }
    ++ [
      {
        vars = {
          VELERO_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
          VELERO_SCRATCH_DIR = "/scratch";
          HOME = "/scratch";
        }
        // extra;
        from = "the package (the pod's namespace or node, and the writable directories it mounts)";
        fix = "Remove it.";
      }
    ];

  emptyDirs =
    names:
    map (n: {
      name = n;
      emptyDir = { };
    }) names;

  credentialVolumes = lib.optional credentialFile (creds.dep.out.volume "cloud-credentials");

  commonMounts =
    lib.optional credentialFile {
      name = "cloud-credentials";
      mountPath = "/credentials";
    }
    ++ [
      {
        name = "scratch";
        mountPath = "/scratch";
      }
      {
        name = "tmpdir";
        mountPath = "/tmp";
      }
    ];

  metricsContainerPort = {
    name = "http-monitoring";
    containerPort = metricsPort;
    protocol = "TCP";
  };

  metricsProbe = {
    httpGet = {
      path = "/metrics";
      port = "http-monitoring";
    };
    initialDelaySeconds = 10;
    periodSeconds = 30;
    timeoutSeconds = 5;
    failureThreshold = 5;
  };

  # The velero binary runs the server and the node agent, and parses flags
  # with cobra and pflag (pkg/cmd/velero/velero.go upstream). Both containers
  # refuse every flag either of them owns.
  metricsAddressArg = {
    flags = [ "--metrics-address=:${toString metricsPort}" ];
    reason = "the probes and the metrics Service use port ${toString metricsPort}.";
  };
  featureArgs = {
    flags = lib.optional (
      config.features != [ ]
    ) "--features=${lib.concatStringsSep "," config.features}";
    names = [ "--features" ];
    from = "the features option";
    fix = "Remove --features and set features instead.";
  };
  # Return the entry of a flag that names a ConfigMap the package builds
  # from `option`. `configMap` is null when the package builds none.
  configMapArg = flag: option: configMap: {
    flags = lib.optional (configMap != null) "${flag}=${configMap.out.name}";
    names = [ flag ];
    from = "the ${option} option";
    fix = "Remove ${flag} and set ${option} instead.";
  };

  plugins =
    lib.optionalAttrs config.awsPlugin.enabled { velero-plugin-for-aws = config.awsPlugin.image; }
    // config.extraPlugins;

  pluginContainer = initName: image: {
    name = initName;
    image = kix.image.ref image;
    imagePullPolicy = image.pullPolicy;
    # The container copies one plugin binary into /target and exits.
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
    securityContext.readOnlyRootFilesystem = true;
    volumeMounts = [
      {
        name = "plugins";
        mountPath = "/target";
      }
    ];
  };

  workloadRequires =
    builtins.attrValues self.crds
    ++ lib.optional (self.repositoryKey != null) self.repositoryKey
    ++ lib.optional (self.externalStoreEgress != null) self.externalStoreEgress;

  crdFile = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
  phase = equals: {
    path = "/status/phase";
    inherit equals;
  };
  # A Backup or Restore runs once. Its controller processes only the
  # ReadyToStart phase (pkg/controller/backup_controller.go and
  # restore_controller.go, the switch on status.phase in Reconcile), so an
  # object that ends in FailedValidation, Failed, or PartiallyFailed stays
  # there, and editing it does not run it again. A Schedule's
  # FailedValidation comes from parsing spec.schedule, which only a spec
  # change alters.
  failedValidation = phase "FailedValidation" // {
    rejected = true;
    message = "/status/validationErrors";
  };
  oneShotReadiness =
    what:
    phase "Completed"
    // {
      failed = [
        failedValidation
      ]
      ++
        map
          (
            value:
            phase value
            // {
              message = "/status/failureReason";
              hint = "Velero does not run a failed ${what} again. Fix the cause shown in its status, then create the ${what} again under a new name.";
            }
          )
          [
            "Failed"
            "PartiallyFailed"
          ];
    };
  scheduleReadiness = phase "Enabled" // {
    failed = [ failedValidation ];
  };
in
{
  # Locations, schedules, repositories, and requests run no pods. A Backup,
  # Restore, DataUpload, DataDownload, PodVolumeBackup, or PodVolumeRestore
  # may run a data mover pod, so those stay undeclared.
  crds = {
    backupRepositories = scope.mkCRD {
      spec = crdFile "backuprepositories.velero.io.json";
      controller = self.deployment;
      usesAtLeast = _: { };
    };
    backups = scope.mkCRD {
      spec = crdFile "backups.velero.io.json";
      controller = self.deployment;
      readiness = oneShotReadiness "backup";
    };
    # Velero's pods dial the store named in the location's config
    # (`s3Url`), not whoever creates the location.
    backupStorageLocations = scope.mkCRD {
      spec = crdFile "backupstoragelocations.velero.io.json";
      controller = self.deployment;
      readiness = phase "Available";
      usesAtLeast = _: { };
      factBehavior = {
        endpoint = "terminate";
        podSelector = scope.selectorLabels;
      };
    };
    dataDownloads = scope.mkCRD { spec = crdFile "datadownloads.velero.io.json"; };
    dataUploads = scope.mkCRD { spec = crdFile "datauploads.velero.io.json"; };
    deleteBackupRequests = scope.mkCRD {
      spec = crdFile "deletebackuprequests.velero.io.json";
      controller = self.deployment;
      usesAtLeast = _: { };
    };
    downloadRequests = scope.mkCRD {
      spec = crdFile "downloadrequests.velero.io.json";
      controller = self.deployment;
      usesAtLeast = _: { };
    };
    podVolumeBackups = scope.mkCRD { spec = crdFile "podvolumebackups.velero.io.json"; };
    podVolumeRestores = scope.mkCRD { spec = crdFile "podvolumerestores.velero.io.json"; };
    restores = scope.mkCRD {
      spec = crdFile "restores.velero.io.json";
      controller = self.deployment;
      readiness = oneShotReadiness "restore";
    };
    schedules = scope.mkCRD {
      spec = crdFile "schedules.velero.io.json";
      controller = self.deployment;
      readiness = scheduleReadiness;
      usesAtLeast = _: { };
    };
    serverStatusRequests = scope.mkCRD {
      spec = crdFile "serverstatusrequests.velero.io.json";
      controller = self.deployment;
      usesAtLeast = _: { };
    };
    volumeSnapshotLocations = scope.mkCRD {
      spec = crdFile "volumesnapshotlocations.velero.io.json";
      usesAtLeast = _: { };
    };
  };

  # Nothing in the pod specs names the repository Secret, because
  # Velero reads it by name, and a server that starts before it exists
  # creates it with the compiled-in key. The workloads require this
  # reference, so the deploy waits for the Secret first.
  repositoryKey =
    if repoPassword == null then
      null
    else
      scope.mkSecretRef {
        name = repoSecretName;
        keys = [ "repository-password" ];
      };

  # The server, node-agent, and every pod they launch run as this
  # ServiceAccount: Velero copies it from its own Deployment and DaemonSet.
  serviceAccount =
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = "${name}-server";
    }
    |> creds.bind
    |> scope.mkResource;

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-server";
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "cluster-admin";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = ns;
        }
      ];
    };
  };

  deployment = scope.mkDeployment {
    name = "velero";
    inherit (config.server) annotations;
    # One server: it has no leader election, and a second would race
    # the first over the same backups.
    availability.max = "none";
    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      # node-agent and data-path pods carry the selector labels too;
      # the component keeps them out of this selector.
      selector.matchLabels = scope.selectorLabels // componentLabels "server";
      template.spec = {
        serviceAccount = self.serviceAccount;
        # On SIGTERM the server cancels its work and exits, and marks
        # in-progress backups and restores Failed at its next start
        # (markInProgressCRsFailed), so a longer grace period lets no
        # backup finish.
        terminationGracePeriodSeconds = 30;
        securityContext = {
          runAsNonRoot = true;
          # `cnb` in the velero image.
          runAsUser = 1002;
        };
        initContainers = lib.mapAttrsToList pluginContainer plugins;
        containers = [
          {
            name = "velero";
            image = kix.image.ref config.image;
            imagePullPolicy = config.image.pullPolicy;
            command = [ "/velero" ];
            args = kix.mergeArgs {
              inherit scope;
              parser = "gnu";
              option = "server.extraArgs";
              args = [
                "server"
                metricsAddressArg
                featureArgs
                (configMapArg "--global-backup-volume-policies-configmap" "volumePolicies" self.volumePolicies)
                (configMapArg "--repo-maintenance-job-configmap" "repositoryMaintenance.settings"
                  self.repositoryMaintenanceConfig
                )
                (configMapArg "--node-agent-configmap" "nodeAgent.settings" null)
              ];
            } config.server.extraArgs;
            env = kix.mkEnvVars (
              kix.mergeEnv {
                inherit scope;
                option = "server.env";
                owned = ownedEnv { LD_LIBRARY_PATH = "/plugins"; };
              } config.server.env
            );
            ports = [ metricsContainerPort ];
            livenessProbe = metricsProbe;
            readinessProbe = metricsProbe;
            resources = config.server.resources;
            securityContext.readOnlyRootFilesystem = true;
            volumeMounts = commonMounts ++ [
              {
                name = "plugins";
                mountPath = "/plugins";
              }
            ];
          }
        ];
        volumes =
          credentialVolumes
          ++ emptyDirs [
            "plugins"
            "scratch"
            "tmpdir"
          ];
      };
    };
    requires = workloadRequires;
  };

  nodeAgent =
    if !config.nodeAgent.enabled then
      null
    else
      scope.mkDaemonSet {
        name = "node-agent";
        inherit (config.nodeAgent) annotations;
        spec = {
          # Velero finds node-agent pods by `role` (pkg/nodeagent/node_agent.go).
          selector.matchLabels =
            scope.selectorLabels
            // componentLabels "node-agent"
            // {
              role = "node-agent";
            };
          template = {
            metadata = {
              # node-agent reads its ConfigMap at start.
              annotations."checksum/node-agent-config" = self.nodeAgentConfig.out.contentHash;
            };
            spec = {
              serviceAccount = self.serviceAccount;
              # node-agent also cancels its work on SIGTERM (see the server).
              terminationGracePeriodSeconds = 30;
              securityContext.runAsUser = 0;
              containers = [
                {
                  name = "node-agent";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/velero" ];
                  args = kix.mergeArgs {
                    inherit scope;
                    parser = "gnu";
                    option = "nodeAgent.extraArgs";
                    args = [
                      "node-agent"
                      "server"
                      metricsAddressArg
                      featureArgs
                      (configMapArg "--node-agent-configmap" "nodeAgent.settings" self.nodeAgentConfig)
                      (configMapArg "--global-backup-volume-policies-configmap" "volumePolicies" null)
                      (configMapArg "--repo-maintenance-job-configmap" "repositoryMaintenance.settings" null)
                    ];
                  } config.nodeAgent.extraArgs;
                  env = kix.mkEnvVars (
                    kix.mergeEnv {
                      inherit scope;
                      option = "nodeAgent.env";
                      owned = ownedEnv { NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName"; };
                    } config.nodeAgent.env
                  );
                  ports = [ metricsContainerPort ];
                  livenessProbe = metricsProbe;
                  readinessProbe = metricsProbe;
                  resources = config.nodeAgent.resources;
                  securityContext.readOnlyRootFilesystem = true;
                  volumeMounts = commonMounts ++ [
                    {
                      name = "host-pods";
                      mountPath = "/host_pods";
                      mountPropagation = "HostToContainer";
                    }
                    {
                      name = "host-plugins";
                      mountPath = "/var/lib/kubelet/plugins";
                      mountPropagation = "HostToContainer";
                    }
                  ];
                }
              ];
              volumes =
                credentialVolumes
                ++ [
                  {
                    name = "host-pods";
                    hostPath.path = "/var/lib/kubelet/pods";
                  }
                  {
                    name = "host-plugins";
                    hostPath.path = "/var/lib/kubelet/plugins";
                  }
                ]
                ++ emptyDirs [
                  "scratch"
                  "tmpdir"
                ];
            };
          };
        };
        requires = workloadRequires;
      };

  # Velero reads the one data key of each of these ConfigMaps, as JSON.
  nodeAgentConfig =
    if !config.nodeAgent.enabled then
      null
    else
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-node-agent";
        data."node-agent.json" = builtins.toJSON (
          withDataPathLabels identityLabels config.nodeAgent.settings
        );
      };

  repositoryMaintenanceConfig =
    if !config.nodeAgent.enabled then
      null
    else
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-repo-maintenance";
        data.global = builtins.toJSON (
          withDataPathLabels identityLabels config.repositoryMaintenance.settings
        );
      };

  # JSON is YAML, which is what Velero decodes.
  volumePolicies =
    if config.volumePolicies == [ ] then
      null
    else
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-volume-policies";
        data."policies.yaml" = builtins.toJSON {
          version = "v1";
          volumePolicies = map renderPolicy config.volumePolicies;
        };
      };

  # DNS and API server egress for the pods Velero launches (file-system
  # backup and restore, data mover, repository maintenance). The store
  # is opened for them by the location's operand policy or by
  # externalStoreEgress, which both select every pod of the instance.
  dataPathEgress =
    if !config.nodeAgent.enabled then
      null
    else
      kix.operandPolicy {
        inherit scope;
        name = "${name}-data-path";
        selector = dataPathLabels;
        egress =
          let
            netpol = scope.networkPolicyEnforcer.netpol;
          in
          [
            netpol.dnsEgressRule
            netpol.apiServerEgressRule
          ]
          ++ (netpol.translateIntentRules { intents.identity = identityMetadata.networkIntents; })
            .egressRules;
      };

  # Egress outside the cluster for every pod of the instance; see
  # externalPorts.
  externalStoreEgress =
    if externalPorts == [ ] then
      null
    else
      kix.operandPolicy {
        inherit scope;
        name = "${name}-external-store";
        selector = scope.selectorLabels;
        egress =
          (scope.networkPolicyEnforcer.netpol.translateIntentRules {
            intents.store.egress = [
              {
                to = "world";
                ports = map (port: {
                  inherit port;
                  protocol = "TCP";
                }) externalPorts;
              }
            ];
          }).egressRules;
      };
}
