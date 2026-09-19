# plugins/spread/module.nix — derived pod spread and PodDisruptionBudgets.
#
# Every multi-replica Deployment/StatefulSet gets topologySpreadConstraints
# on the cluster's failure-domain keys, and a PDB, without the package
# writing either. The package states intent in `spec.replicas`; the cluster
# states what a failure domain is (`cluster.capabilities.availabilityZones`,
# `multiNode`); the operator states how strict to be (`cluster.spread`).
# Design: v2_discussions/143_pod_spread_and_failure_zones.md.
#
# Two hooks:
#   workloadInterceptors.spread  — the podSpec patch, pre-seal (§1, §3, §4)
#   instanceProcessors.spread    — the PDB, post-fixpoint so an author-written
#                                  PDB in the same instance is seen (§7)
{
  config,
  lib,
  ...
}:

let
  cfg = config.cluster.spread;
  caps = config.cluster.capabilities;

  zoneKey = "topology.kubernetes.io/zone";
  hostKey = "kubernetes.io/hostname";

  modes = [
    "off"
    "soft"
    "hard-zones"
    "hard"
  ];

  spreadKinds = [
    "Deployment"
    "StatefulSet"
  ];

  zones = caps.availabilityZones or null;
  multiNode = caps.multiNode or null;

  # §2. Three-valued: multiNode=false derives nothing; zones unknown or
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

  # §3. hard-zones is hard on the zone key only; on a cluster without a
  # zone key it behaves as soft, which is the visible-degrade rule.
  whenUnsatisfiable =
    mode: key:
    if mode == "hard" then
      "DoNotSchedule"
    else if mode == "hard-zones" && key == zoneKey then
      "DoNotSchedule"
    else
      "ScheduleAnyway";

  instanceMode =
    ns: inst:
    let
      override = ((config.instances.${ns} or { }).${inst} or { }).spread or null;
    in
    if override != null then override else cfg.default;

  # The one decision both hooks share: does this workload get derived
  # spread at all. Returns null when not, else the mode.
  applicableMode =
    {
      kind,
      spec,
      instanceName,
      namespaceName,
      packageMeta,
    }:
    let
      replicas = spec.replicas or null;
      mode = instanceMode namespaceName instanceName;
    in
    if
      !(builtins.elem kind spreadKinds)
      || !(builtins.isInt replicas)
      || replicas <= 1
      || mode == "off"
      || failureDomainKeys == [ ]
      || (packageMeta.spread or true) == false
    then
      null
    else
      mode;

  mkConstraints =
    mode: selector:
    map (key: {
      topologyKey = key;
      maxSkew = 1;
      whenUnsatisfiable = whenUnsatisfiable mode key;
      labelSelector.matchLabels = selector;
    }) failureDomainKeys;

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
    cluster.spread = {
      default = lib.mkOption {
        type = lib.types.enum modes;
        default = "hard-zones";
        description = ''
          How strictly derived topology spread is enforced, cluster-wide.
          "hard-zones" (default): DoNotSchedule on the zone key, ScheduleAnyway
          on hostname. "hard": DoNotSchedule on every key. "soft":
          ScheduleAnyway everywhere. "off": derive nothing. With maxSkew = 1
          a DoNotSchedule constraint is even distribution, not one pod per
          domain, so more replicas than domains is fine; what it refuses is a
          domain that cannot take its share (a zone with no ready nodes).
          Per-instance override: instances.<ns>.<inst>.spread.
          See v2_discussions/143.
        '';
      };
    };

    cluster.topology.failureDomainKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The topology keys a pod should be spread across on this cluster,
        outermost first. Computed from cluster.capabilities: zones declared
        and more than one gives [ zone, hostname ]; otherwise [ hostname ];
        multiNode = false gives [ ]. Packages whose pods are rendered by an
        operator read this (clusterConfig.cluster.topology.failureDomainKeys)
        instead of naming a key.
      '';
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options.spread = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum modes);
              default = null;
              description = ''
                Override cluster.spread.default for this instance. "off"
                is the operator's escape hatch for a workload whose replicas
                are not about availability.
              '';
            };
          }
        )
      );
    };
  };

  config = {
    cluster.topology.failureDomainKeys = failureDomainKeys;

    hooks.workloadInterceptors.spread =
      ctx:
      let
        spec = ctx.workloadInput.spec or { };
        templateSpec = spec.template.spec or { };
        name = ctx.workloadInput.name or ctx.workloadInput.metadata.name or "?";
        mode = applicableMode {
          inherit (ctx) instanceName namespaceName packageMeta;
          kind = ctx.workloadKind;
          inherit spec;
        };
        # meta.spread = false is the maintainer's opt-out; it exists for the
        # genuine case and should read as unusual in every build log.
        optedOut =
          builtins.elem ctx.workloadKind spreadKinds
          && builtins.isInt (spec.replicas or null)
          && (spec.replicas or 0) > 1
          && (ctx.packageMeta.spread or true) == false
          && failureDomainKeys != [ ];
      in
      {
        warnings = lib.optional optedOut (
          "[${ctx.instanceName}] ${ctx.workloadKind} '${name}' runs ${toString spec.replicas} replicas "
          + "and its package sets meta.spread = false, so it gets no derived spread or PDB. "
          + "Spread is normally the cluster operator's decision (instances.<ns>.<inst>.spread)."
        );
        podSpec =
          if mode == null || templateSpec ? topologySpreadConstraints then
            { }
          else
            {
              topologySpreadConstraints = mkConstraints mode ctx.selector;
            };
      };

    hooks.instanceProcessors.spread =
      ctx:
      let
        manifests = builtins.filter (m: m ? kind) (map (r: r.rawManifest or { }) ctx.allPartResources);
        pdbs = builtins.filter (m: m.kind == "PodDisruptionBudget") manifests;
        wantsPdb =
          m:
          applicableMode {
            inherit (ctx) instanceName namespaceName packageMeta;
            inherit (m) kind spec;
          } != null
          && !(builtins.any (isCoveredBy m) pdbs);
        mkPdb =
          m:
          let
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
      in
      {
        resources = map mkPdb (builtins.filter wantsPdb manifests);
      };

    # One line per cluster, not per workload: the cluster spreads across
    # hosts only because nobody declared its zones.
    hooks.clusterProcessors.spread = _ctx: {
      warnings = lib.optional (multiNode != false && zones == null && cfg.default != "off") (
        "[kix] cluster.capabilities.availabilityZones is unknown, so derived pod spread uses "
        + "kubernetes.io/hostname only. Declare the zones (or [ ] for single-zone) in the target."
      );
    };
  };
}
