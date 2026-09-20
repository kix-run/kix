# plugins/availability/module.nix — the availability level, and what the
# compiler derives from it: topology spread, PodDisruptionBudgets, and the
# checks that the level is honoured.
#
# The package states intent in `spec.replicas` (mapping the level it was
# given as its `availability` argument); the cluster states what a failure
# domain is (`cluster.capabilities.availabilityZones`, `multiNode`); the
# operator states how much failure to survive (`cluster.availability`).
# Design: v2_discussions/archive/145_availability_level.md (spread mechanism from
# archive/143).
#
# The level itself is resolved once per instance in eval/instance.nix
# (core/availability.nix `resolve`) and arrives here as `ctx.availability`.
# Three hooks:
#   workloadInterceptors.availability — the podSpec patch, pre-seal
#   instanceProcessors.availability   — the PDB, the ladder's warnings and
#                                       the shortfall check, post-fixpoint
#   clusterProcessors.availability    — one warning per cluster when the
#                                       substrate is uncertain
{
  config,
  lib,
  ...
}:

let
  avail = import ../../core/availability.nix { inherit lib; };
  caps = config.cluster.capabilities;

  # The labels that name a zone and a host. Both default to the well-known
  # Kubernetes labels; a cluster whose nodes are labelled by hand (racks,
  # hypervisor hosts, no cloud controller) sets its own.
  zoneKey = config.cluster.topology.zoneKey;
  hostKey = config.cluster.topology.hostKey;

  spreadKinds = [
    "Deployment"
    "StatefulSet"
  ];

  zones = caps.availabilityZones or null;
  multiNode = caps.multiNode or null;
  substrate = avail.substrate caps;

  # Three-valued: multiNode=false derives nothing; zones unknown or
  # single-zone spreads across hosts only. The rename onto doc 127's
  # cluster.substrate.topology happens here and nowhere else.
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

  # Strictness is a lowering of the level (145 §6): hard on the key that
  # names the level, best effort on the others. With maxSkew = 1 a hard
  # constraint is even distribution, not one pod per domain, so more
  # replicas than domains is fine; what it refuses is a domain that cannot
  # take its share.
  whenUnsatisfiable =
    level: key:
    if level == "zone" && key == zoneKey then
      "DoNotSchedule"
    else if level == "node" && key == hostKey then
      "DoNotSchedule"
    else
      "ScheduleAnyway";

  isMultiReplica =
    kind: spec:
    builtins.elem kind spreadKinds && builtins.isInt (spec.replicas or null) && spec.replicas > 1;

  # The author has taken over placement for this workload: the compiler
  # derives neither constraints nor a PDB for it (one signal, one meaning).
  authorPlaced = spec: (spec.template.spec or { }) ? topologySpreadConstraints;

  # nodeTaintsPolicy = Honor: a node the pod cannot land on (a tainted
  # control plane) must not count as a domain with zero pods, or a hard
  # hostname constraint caps every worker at one pod. Found on kind: with
  # the zone key also hard the control plane was excluded for lacking a
  # zone label, which hid it; with hostname alone it blocked the fourth pod.
  # matchLabelKeys = [ pod-template-hash ] on Deployments: during a rolling
  # update the new pods are counted against the old ones, so once the old
  # ones leave a domain can be empty. Keying on the revision counts only
  # the new pods. StatefulSets replace pods in place and have no such label.
  mkConstraints =
    kind: level: selector:
    map (
      key:
      {
        topologyKey = key;
        maxSkew = 1;
        whenUnsatisfiable = whenUnsatisfiable level key;
        nodeTaintsPolicy = "Honor";
        labelSelector.matchLabels = selector;
      }
      // lib.optionalAttrs (kind == "Deployment") { matchLabelKeys = [ "pod-template-hash" ]; }
    ) failureDomainKeys;

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
        labelled by hand (racks, hypervisor hosts, no cloud controller)
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
        # Post-seal the manifest carries the derived constraints, so "the
        # author placed this" is "constraints are present and are not the
        # ones we would have derived" (a pure function of level and
        # selector). No constraints at all means a workload the seal never
        # patched (a raw mkResource Deployment, housekeeping 2026-09-19); it
        # still gets its PDB.
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

        # The derivation skips a workload the package placed itself (one
        # signal, one meaning), so that workload has no PDB unless the
        # package wrote one. Here the skip is decided, so here it is said:
        # a scorecard rule could see the derived PDBs now (the rules score
        # the shipped set since 2026-09-20) but not why one is absent.
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

        # 145 §7: the package promised to honour the level; check the
        # result. From "node" up every root-reachable workload must run more
        # than one replica (at "pod" a stateful component may still be
        # standalone by design, §5.3). Ancillary workloads off the root path
        # are not judged.
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

    # One line per cluster, not per instance: what the derived level rests on.
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
