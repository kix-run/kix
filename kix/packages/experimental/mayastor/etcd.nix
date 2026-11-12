# etcd, Mayastor's store for its volume, replica, and nexus records, as a
# StatefulSet configured through the Bitnami variables of the openebs/etcd
# image, with authentication off as upstream runs it.
#
# Members: one at availability `none`, three above, spread one per node by
# the availability plugin. Three members need three nodes on which the
# etcd class can provision a volume (a node-local class limited by
# `allowedTopologies` counts only its listed nodes); with fewer, a member
# stays Pending and the deploy does not converge. A member's data directory
# lists every member, so changing the level of a live instance is an etcd
# membership change: run `etcdctl member add` before scaling up or
# `etcdctl member remove` before scaling down, or restore an
# `etcdctl snapshot save` into a fresh cluster.
#
# The class of the members' volumes, checked in this order:
#   1. refused when this instance answers `storageClasses` itself, through
#      its own aliases with no explicit dependency or through an explicit
#      `deps.storageClasses` that names it. Kix then resolves the
#      dependency to this instance, and evaluating it recurses even when
#      etcd's class is named below, so this check comes first;
#   2. `etcd.storage.storageClassName`, unless it names one of this
#      instance's classes;
#   3. refused when nothing provides `storageClasses`;
#   4. the dependency's `out.storageClassName`, unless it is one of this
#      instance's classes or the provider's `out.provisioner` is this
#      instance's CSI driver.
# etcd on a Mayastor volume cannot start after a full restart, because
# Mayastor needs etcd to bring its volumes up.
{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
  availability,
  storageClasses ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) name ns who;

  members = kix.availability.pick availability {
    none = 1;
    pod = 3;
    node = 3;
    zone = 3;
  };
  statefulSetName = "${name}-etcd";

  ownClasses = builtins.attrNames config.storageClasses;
  onOwnVolume = "etcd must not live on a Mayastor volume: Mayastor needs etcd to bring its volumes up, so etcd could not start after a full restart.";
  storageFix = "Wire deps.storageClasses to a local provider (a zfs-localpv or storage-classes instance, or an import of a class the cluster already has: kix.mkImport { out.storageClassName = \"local-path\"; }), or set config.etcd.storage.storageClassName to a class that is not Mayastor's. A cloud block class also works.";

  instance = clusterConfig.instances.${ns}.${name} or { };
  depRef = (instance.deps or { }).storageClasses or null;
  selfByRef =
    builtins.isAttrs depRef
    && (depRef._type or null) == "kix-ref"
    && depRef.namespace == ns
    && depRef.instanceName == name;
  selfByAlias = builtins.elem "storageClasses" (
    if (instance.aliases or null) == null then [ ] else instance.aliases
  );

  storageClassName =
    let
      named = config.etcd.storage.storageClassName;
    in
    if selfByRef || (selfByAlias && depRef == null) then
      throw "${who}: this instance answers deps.storageClasses itself, so etcd cannot take its class from that dependency. ${onOwnVolume} Wire deps.storageClasses to a local provider, for example deps.storageClasses = ref.<ns>.<zfs-localpv instance>, or to an import of the class etcd should use (kix.mkImport { out.storageClassName = \"local-path\"; })."
    else if named != null then
      if builtins.elem named ownClasses then
        throw "${who}: config.etcd.storage.storageClassName is \"${named}\", one of this instance's own StorageClasses. ${onOwnVolume} ${storageFix}"
      else
        named
    else if storageClasses == null then
      throw "${who}: etcd needs a StorageClass that is not Mayastor's, and nothing provides the storageClasses dependency. ${storageFix}"
    else if
      builtins.elem storageClasses.out.storageClassName ownClasses
      || (storageClasses.out.provisioner or null) == self.csiDriver.out.name
    then
      throw "${who}: the storageClasses dependency gives etcd the class \"${storageClasses.out.storageClassName}\", which Mayastor provisions. ${onOwnVolume} ${storageFix}"
    else
      storageClasses.out.storageClassName;

  # Bitnami's scripts read the quota in bytes. Upstream's 8 GiB on a 2 GiB
  # claim fills the volume before etcd raises its space alarm.
  quotaBytes =
    let
      bytes = kix.parseQuantity "storage" config.etcd.storage.size;
    in
    if builtins.isInt bytes then bytes * 8 / 10 else builtins.floor (bytes * 0.8);

  headless = self.etcdHeadless.out.fqdn;
  peerUrl = member: "http://${member}.${headless}:2380";
  initialCluster = lib.concatMapStringsSep "," (
    i:
    let
      member = "${statefulSetName}-${toString i}";
    in
    "${member}=${peerUrl member}"
  ) (lib.range 0 (members - 1));

  # Kubernetes expands $(VAR) in an env value only from variables listed
  # before it, so the pod's own name and IP come first.
  podVars = [
    {
      name = "MY_POD_NAME";
      valueFrom.fieldRef.fieldPath = "metadata.name";
    }
    {
      name = "MY_POD_IP";
      valueFrom.fieldRef.fieldPath = "status.podIP";
    }
  ];

  env =
    podVars
    ++ kix.mkEnvVars (
      kix.mergeEnv {
        inherit who;
        defaults = {
          ETCD_LOG_LEVEL = "info";
          ETCD_AUTO_COMPACTION_MODE = "revision";
          ETCD_AUTO_COMPACTION_RETENTION = "100";
        };
        owned = [
          {
            names = map (v: v.name) podVars;
            from = "the pod (Downward API), listed first so the variables below can expand them";
            fix = "Remove it from etcd.env.";
          }
          {
            vars = {
              MY_STS_NAME = statefulSetName;
              ETCD_ON_K8S = "yes";
              ETCD_START_FROM_SNAPSHOT = "no";
              ETCD_DISASTER_RECOVERY = "no";
              ETCD_NAME = "$(MY_POD_NAME)";
              ETCD_DATA_DIR = "/bitnami/etcd/data";
              ALLOW_NONE_AUTHENTICATION = "yes";
              ETCD_AUTH_TOKEN = "simple";
              ETCD_LISTEN_CLIENT_URLS = "http://0.0.0.0:2379";
              ETCD_LISTEN_PEER_URLS = "http://0.0.0.0:2380";
              ETCD_LISTEN_METRICS_URLS = "http://0.0.0.0:9090";
              ETCD_ADVERTISE_CLIENT_URLS = "http://$(MY_POD_NAME).${headless}:2379";
              ETCD_INITIAL_ADVERTISE_PEER_URLS = "http://$(MY_POD_NAME).${headless}:2380";
              ETCD_INITIAL_CLUSTER_TOKEN = "etcd-cluster-k8s";
              ETCD_INITIAL_CLUSTER = initialCluster;
              ETCD_CLUSTER_DOMAIN = headless;
              ETCD_QUOTA_BACKEND_BYTES = toString quotaBytes;
            };
            from = "the package: member names and URLs follow the StatefulSet and its headless Service, the quota follows etcd.storage.size, and authentication is off";
            fix = "Remove it from etcd.env; set etcd.storage.size for the quota.";
          }
        ];
      } config.etcd.env
    );

  ports = {
    client = {
      name = "client";
      port = 2379;
      targetPort = 2379;
      protocol = "TCP";
    };
    peer = {
      name = "peer";
      port = 2380;
      targetPort = 2380;
      protocol = "TCP";
    };
  };
in
{
  etcd = scope.mkStatefulSet {
    name = statefulSetName;
    spec = {
      headlessService = self.etcdHeadless;
      replicas = members;
      # Members must start together to form the initial cluster.
      podManagementPolicy = "Parallel";
      updateStrategy.type = "RollingUpdate";
      selector.matchLabels = c.componentLabels "etcd";
      template.spec = {
        serviceAccount = self.etcdServiceAccount;
        automountServiceAccountToken = false;
        priorityClassName = "system-cluster-critical";
        terminationGracePeriodSeconds = 30;
        securityContext = {
          fsGroup = 1001;
          fsGroupChangePolicy = "Always";
        };
        # A hostPath-backed class ignores fsGroup.
        initContainers = [
          {
            name = "volume-permissions";
            image = kix.image.ref config.init.image;
            imagePullPolicy = config.init.image.pullPolicy;
            command = [
              "sh"
              "-ec"
              "chown -R 1001:1001 /bitnami/etcd"
            ];
            resources = c.initResources;
            securityContext = {
              runAsUser = 0;
              readOnlyRootFilesystem = true;
            };
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
            image = kix.image.ref config.etcd.image;
            imagePullPolicy = config.etcd.image.pullPolicy;
            inherit env;
            ports = [
              (kix.port "client" 2379)
              (kix.port "peer" 2380)
              (kix.port "health" 9090)
            ];
            livenessProbe = {
              httpGet = {
                path = "/livez";
                port = 9090;
              };
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
            resources = config.etcd.resources;
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              readOnlyRootFilesystem = true;
              runAsNonRoot = true;
              runAsUser = 1001;
              runAsGroup = 1001;
              seccompProfile.type = "RuntimeDefault";
            };
            volumeMounts = [
              {
                name = "empty-dir";
                mountPath = "/opt/bitnami/etcd/conf/";
                subPath = "app-conf-dir";
              }
              {
                name = "empty-dir";
                mountPath = "/tmp";
                subPath = "tmp-dir";
              }
              {
                name = "data";
                mountPath = "/bitnami/etcd";
              }
            ];
          }
        ];
        volumes = [
          {
            name = "empty-dir";
            emptyDir = { };
          }
        ];
      };
      volumeClaimTemplates = [
        {
          metadata.name = "data";
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = config.etcd.storage.size;
            inherit storageClassName;
          };
        }
      ];
    };
  };

  # Members find each other through this Service before they are Ready, so
  # it publishes unready addresses. The members' env reads its `out.fqdn`,
  # so it selects with the StatefulSet's `rawSelector`; `out.selector` would
  # recurse.
  etcdHeadless = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-etcd-headless";
    labels = c.componentLabels "etcd-headless";
    spec = {
      clusterIP = "None";
      publishNotReadyAddresses = true;
      selector = self.etcd.rawSelector;
      ports = [
        ports.client
        ports.peer
      ];
    };
  };

  # Clients dial this Service, so they wait for Ready members.
  etcdService =
    self.etcd
    |> kix.service.fromWorkload {
      name = "${name}-etcd";
      labels = c.componentLabels "etcd";
      ports = [ ports.client ];
    }
    |> scope.mkResource;
}
