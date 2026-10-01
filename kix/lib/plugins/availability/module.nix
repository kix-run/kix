# Derive topology spread and PodDisruptionBudgets from availability levels.
#
# Packages map ctx.availability to replica counts. Cluster capabilities define
# available failure domains. The workload interceptor adds placement before
# sealing; the instance processor adds PDBs and checks replica shortfalls; the
# cluster processor reports uncertain substrate capabilities once per cluster.
{
  config,
  lib,
  ...
}:

let
  avail = import ../../core/availability.nix { inherit lib; };
  caps = config.cluster.capabilities;

  # Labels identifying zone and host failure domains. Clusters with custom
  # node labels can override the Kubernetes defaults.
  zoneKey = config.cluster.topology.zoneKey;
  hostKey = config.cluster.topology.hostKey;

  spreadKinds = [
    "Deployment"
    "StatefulSet"
  ];

  zones = caps.availabilityZones or null;
  multiNode = caps.multiNode or null;
  substrate = avail.substrate caps;

  # Derive no topology keys for a confirmed single-node cluster. Unknown or
  # single-zone clusters spread by host; multi-zone clusters add the zone key.
  failureDomainKeys =
    if multiNode == false then
      [ ]
    else if zones != null && builtins.length zones > 1 then
      [
        zoneKey
        hostKey
      ]
    else
      [ hostKey ];

  isMultiReplica =
    kind: spec:
    builtins.elem kind spreadKinds && builtins.isInt (spec.replicas or null) && spec.replicas > 1;

  # The author has taken over placement for this workload: the compiler
  # derives neither constraints nor a PDB for it (one signal, one meaning).
  authorPlaced = spec: (spec.template.spec or { }) ? topologySpreadConstraints;

  # The constraints come from core/availability.nix. For a Deployment,
  # matchLabelKeys counts only the current revision during a rolling
  # update; StatefulSets replace pods in place and have no
  # pod-template-hash label.
  mkConstraints =
    kind: level: selector:
    map (c: c // lib.optionalAttrs (kind == "Deployment") { matchLabelKeys = [ "pod-template-hash" ]; })
      (
        avail.spreadConstraints {
          inherit level selector;
          topology = {
            inherit zoneKey hostKey failureDomainKeys;
          };
        }
      );

  # A PDB written by the author covers a workload when its selector is a
  # subset of the workload's template labels.
  isCoveredBy =
    workloadManifest: pdbManifest:
    let
      want = pdbManifest.spec.selector.matchLabels or null;
      have = workloadManifest.spec.template.metadata.labels or { };
    in
    want != null
    && want != { }
    && builtins.all (k: (have.${k} or null) == want.${k}) (builtins.attrNames want);
in
{
  options = {
    cluster.availability = {
      default = lib.mkOption {
        type = lib.types.enum avail.levels;
        description = ''
          The largest failure a workload must survive without downtime,
          cluster-wide: "none" (downtime on any failure or update is
          accepted), "pod" (a pod crash or rolling update), "node" (the loss
          of one node), "zone" (the loss of one zone). Derived from
          cluster.capabilities when unset: multiNode = false gives "none",
          two or more availabilityZones give "zone", otherwise "node".
          Packages map the level onto their replica counts and quorums; the
          compiler derives topology spread and a PodDisruptionBudget for
          every workload above one replica. A level the substrate cannot
          honour is an error. Per-instance override:
          instances.<ns>.<inst>.availability. See v2_discussions/145.
        '';
      };
      substrate = lib.mkOption {
        type = lib.types.enum avail.levels;
        readOnly = true;
        description = ''
          The largest level this cluster's capabilities can honour, and the
          default for cluster.availability.default.
        '';
      };
    };

    cluster.topology.zoneKey = lib.mkOption {
      type = lib.types.str;
      default = "topology.kubernetes.io/zone";
      description = ''
        The node label whose value names the availability zone. Cloud
        controllers set the well-known default; a cluster whose nodes are
        using custom labels (racks, hypervisor hosts, no cloud controller)
        names its own label here. A flavor may set it with mkDefault.
      '';
    };

    cluster.topology.hostKey = lib.mkOption {
      type = lib.types.str;
      default = "kubernetes.io/hostname";
      description = ''
        The node label whose value names the node. The kubelet sets the
        well-known default on every node, so this rarely changes.
      '';
    };

    cluster.topology.failureDomainKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The topology keys a pod should be spread across on this cluster,
        outermost first. Computed from cluster.capabilities: zones declared
        and more than one gives [ zoneKey, hostKey ]; otherwise [ hostKey ];
        multiNode = false gives [ ]. Packages whose pods are rendered by an
        operator read this (clusterConfig.cluster.topology.failureDomainKeys)
        instead of naming a key.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options.availability = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum avail.levels);
              default = null;
              description = ''
                Override cluster.availability.default for this instance. May
                exceed the cluster default up to what the substrate allows.
                "none" is the operator's escape hatch for a workload whose
                replicas are not about availability.
              '';
            };
          }
        )
      );
    };
  };

  config = {
    cluster.availability.default = lib.mkDefault substrate.level;
    cluster.availability.substrate = substrate.level;
    cluster.topology.failureDomainKeys = failureDomainKeys;

    hooks.workloadInterceptors.availability =
      ctx:
      let
        spec = ctx.workloadInput.spec or { };
        derive = isMultiReplica ctx.workloadKind spec && failureDomainKeys != [ ] && !(authorPlaced spec);
      in
      {
        podSpec = lib.optionalAttrs derive {
          topologySpreadConstraints = mkConstraints ctx.workloadKind ctx.availability.level ctx.selector;
        };
      };

    hooks.instanceProcessors.availability =
      ctx:
      let
        # A workload sealed under its own ceiling (`availability.max` on
        # the builder call) carries the level it was sealed at; every other
        # resource is judged at the instance's.
        levelOf = r: (r._availability or ctx.availability).level;
        workloads = builtins.filter (r: (r.rawManifest or { }) ? kind) ctx.allPartResources;
        manifests = map (r: r.rawManifest) workloads;
        pdbs = builtins.filter (m: m.kind == "PodDisruptionBudget") manifests;
        # Constraints that differ from deriveConstraints are package supplied;
        # skip PDB derivation for those workloads. A workload with no constraints
        # still receives a PDB.
        derivedConstraints =
          r:
          let
            m = r.rawManifest;
          in
          mkConstraints m.kind (levelOf r) (m.spec.selector.matchLabels or { });
        authorPlacedSealed =
          r:
          let
            sealed = r.rawManifest.spec.template.spec.topologySpreadConstraints or null;
          in
          sealed != null && sealed != derivedConstraints r;
        wantsPdb =
          r:
          let
            m = r.rawManifest;
          in
          isMultiReplica m.kind m.spec
          && failureDomainKeys != [ ]
          && !(authorPlacedSealed r)
          && !(builtins.any (isCoveredBy m) pdbs);
        mkPdb =
          r:
          let
            m = r.rawManifest;
            ns = m.metadata.namespace or ctx.namespaceName;
            emitter = if ns == ctx.namespaceName then ctx.emit else ctx.emit.inNamespace ns;
          in
          emitter.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = m.metadata.name;
            spec = {
              maxUnavailable = 1;
              selector.matchLabels = m.spec.selector.matchLabels;
            };
          };

        # Warn when package-supplied placement disables PDB derivation and no
        # package-supplied PDB selects the workload.
        uncoveredPlaced = builtins.filter (
          r:
          let
            m = r.rawManifest;
          in
          isMultiReplica m.kind m.spec
          && failureDomainKeys != [ ]
          && authorPlacedSealed r
          && !(builtins.any (isCoveredBy m) pdbs)
        ) workloads;
        placedWarnings = map (
          r:
          let
            m = r.rawManifest;
          in
          "[${ctx.instanceName}] ${m.kind} '${m.metadata.name}' sets its own "
          + "topologySpreadConstraints, so the compiler derives neither spread nor a "
          + "PodDisruptionBudget for it, and no PodDisruptionBudget in this instance "
          + "selects its pods: a drain can take every replica at once. Write one, or "
          + "drop the constraints and let the availability level derive both."
        ) uncoveredPlaced;

        # At node and zone levels, require each root-reachable workload to run
        # more than one replica. Do not judge ancillary workloads outside the
        # root closure.
        shortfall = builtins.filter (
          r:
          let
            m = r.rawManifest or { };
          in
          builtins.elem (m.kind or "") spreadKinds
          && builtins.isInt (m.spec.replicas or null)
          && m.spec.replicas < 2
          && avail.atLeast "node" (levelOf r)
          && ctx.forwardReachable r
        ) ctx.allPartResources;
        shortfallWarnings = map (
          r:
          "[${ctx.instanceName}] ${r.rawManifest.kind} '${r.rawManifest.metadata.name}' runs "
          + "${toString r.rawManifest.spec.replicas} replica under availability \"${levelOf r}\": "
          + "losing its node would cause downtime. Set the replica count based on the availability level "
          + "(kix.availability.pick), set meta.availability.max to the level the package supports, "
          + "or availability.max on this workload alone."
        ) shortfall;
      in
      {
        resources = map mkPdb (builtins.filter wantsPdb workloads);
        warnings = ctx.availability.warnings ++ placedWarnings ++ shortfallWarnings;
      };

    # Report uncertain substrate capabilities once per cluster.
    hooks.clusterProcessors.availability = _ctx: {
      warnings =
        lib.optional (multiNode == null) (
          "[kix] cluster.capabilities.multiNode is unknown, so availability is derived as "
          + "\"${substrate.level}\" and Kix cannot verify whether required pod placement rules can be met. Set cluster.capabilities.multiNode to match your environment."
        )
        ++ lib.optional (multiNode == true && zones == null) (
          "[kix] cluster.capabilities.availabilityZones is unknown, so availability is derived as "
          + "\"node\" and derived pod spread uses ${hostKey} only. Declare the zones "
          + "(or [ ] for a single zone) in the cluster definition."
        );
    };
  };
}
