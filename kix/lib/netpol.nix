# lib/netpol.nix — CiliumNetworkPolicy derivation from DI graph.
#
# Derives network policies from the store-path dependency graph:
# - Egress: per-workload, computed inside evaluateInstance
# - Ingress: per-service, computed after fixpoint in cluster.nix
# - Default-deny: per-namespace
#
# Auto-detects (no meta fields needed):
# - API server access: instance has RBAC or CRD resources
# - External ingress: instance has LoadBalancer Service or hostNetwork workload
# - Self-communication: StatefulSet workloads
# - hostNetwork bypass: warning (NetworkPolicy has no effect)
# - Helm opacity: warning (intra-package edges may be missing)

{
  lib,
  k8s,
}:

let
  # Build a CiliumNetworkPolicy by routing through the enforcer's
  # `cnpCrdRef.out.cr`. That builder stamps `apiVersion`/`kind` and adds
  # the CRD import marker to `requires`, so every CNP transitively
  # depends on the enforcer's root (via the marker's `installedBy`).
  #
  # There is no fallback for a missing enforcer: an unrouted CNP would
  # land in the wave graph without a store-path edge to cilium and race
  # the operator at apply time. Cluster-level eval asserts that an
  # enforcer is resolved before scope construction (see
  # `kix/lib/eval/cluster.nix` → `enforcerOut`), so reaching this helper
  # with a null enforcer is a programmer error.
  #
  # `mkResource` is the function used to materialize the resulting attrs
  # (typically `scope.mkResource` for instance-level CNPs and
  # `k8s.mkResource` for cluster-level ones).
  #
  # `extraArgs` carries the remaining CNP fields (name, namespace, spec,
  # labels, extraDeps, ...).
  buildCnp =
    {
      networkPolicyEnforcer,
      mkResource,
      extraArgs,
    }:
    if networkPolicyEnforcer == null || (networkPolicyEnforcer.cnpCrdRef or null) == null then
      throw (
        "kix.netpol: buildCnp called without a resolved network-policy enforcer. "
        + "This indicates a missing cluster-level assertion — cluster.nix should "
        + "have thrown at eval time. Please file a bug."
      )
    else
      mkResource (networkPolicyEnforcer.cnpCrdRef.out.cr extraArgs);

  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
  ];

  isWorkload = r: builtins.elem (r.kind or "") workloadKinds;

  isService =
    r:
    (r.kind or "") == "Service"
    && (r.rawManifest.spec.selector or { }) != { }
    && (r.rawManifest.spec.type or "ClusterIP") != "ExternalName";

  # Build store-path → resource lookup filtered to Services.
  mkServiceRegistry =
    resources:
    builtins.foldl' (
      acc: r:
      acc
      // {
        ${builtins.unsafeDiscardStringContext r.outPath} = r;
      }
    ) { } (builtins.filter isService resources);

  # Extract Service edges from a workload's JSON string-context. Used by
  # `buildWorkloadCnps` which runs inside `scope.mkDeployment` — before the
  # workload resource exists — and extracts edges directly from the caller's
  # args JSON. The store-path context on the JSON is identical to what the
  # built `rawManifest` would carry (same input attrs). Post-fixpoint
  # code no longer re-extracts edges: inverted ingress is emitted
  # caller-side at scope-time (v2_discussions/83 Phase C).
  extractServiceEdgesFromJson =
    { json, serviceRegistry }:
    let
      ctx = builtins.getContext json;
      matchedPaths = builtins.filter (p: builtins.hasAttr p serviceRegistry) (builtins.attrNames ctx);
    in
    map (
      p:
      let
        svc = serviceRegistry.${p};
      in
      {
        service = svc;
        ports = svc.rawManifest.spec.ports or [ ];
        targetSelector = svc.rawManifest.spec.selector or { };
        targetNamespace = k8s.nsOf svc;
      }
    ) matchedPaths;

  # Convert K8s Service ports to Cilium toPorts format.
  # Uses targetPort (pod port), not port (service port).
  portsToCilium =
    ports:
    builtins.filter (p: p != null) (
      map (
        p:
        let
          tp = p.targetPort or p.port or null;
        in
        if tp == null then
          null
        else
          {
            port = toString tp;
            protocol = p.protocol or "TCP";
          }
      ) ports
    );

  # --- Cilium rule templates ---

  dnsEgressRule = {
    toEndpoints = [
      {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = "kube-system";
          "k8s-app" = "kube-dns";
        };
      }
    ];
    toPorts = [
      {
        ports = [
          {
            port = "53";
            protocol = "UDP";
          }
          {
            port = "53";
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  apiServerEgressRule = {
    toEntities = [ "kube-apiserver" ];
  };

in
rec {

  # Expose the helpers that scope-level interception uses.
  inherit mkServiceRegistry isService isWorkload;

  # ── Per-workload CNP builder (scope-level, pre-toFile) ────────────────
  #
  # Called from `scope.mkWorkload` BEFORE the workload resource is built
  # (see v2_discussions/83 "scope-level workload interception"). Takes the
  # raw workload args (pre-mkResource), extracts cross-package Service
  # edges directly from the args' string context, and emits the per-workload
  # egress / self-ingress CiliumNetworkPolicies. The returned CNPs are
  # spliced into the workload's `extraDeps` by `mkWorkload`, so the
  # workload's store-path context transitively includes its CNPs — closing
  # the "unenforced window" where a workload becomes ready before its
  # policies are applied.
  #
  # This does NOT emit rules for `needsApiServerAccess` or
  # `needsExternalIngress`: those require post-fixpoint signals
  # (RBAC/CRD presence, LoadBalancer / hostNetwork detection across the
  # whole instance) and stay in `processInstance` where they run against
  # `allPartResources`. The supplementary CNPs emitted there depend on
  # workloads the old way (CNP → workload), which is fine: they add
  # permissions rather than gate readiness.
  #
  # Arguments:
  #   scope           - calling scope (mkResource used for CNP construction)
  #   instanceName    - passed through for CNP names
  #   namespaceName   - passed through for edge source labels
  #   workloadInput   - the user-provided `attrs` to mkWorkload, post
  #                     spec/serviceAccount/headlessService expansion
  #   workloadKind    - "Deployment" | "StatefulSet" | "DaemonSet"
  #   wSelector       - spec.selector.matchLabels
  #   hostNetwork     - spec.template.spec.hostNetwork (skip netpol if true)
  #   serviceRegistry - path → Service resource (for cross-package edges)
  #   networkConfig   - clusterConfig.networkPolicy (directions etc.)
  #   packageNetworkMeta - packageMeta.network or {} (extraEgress, etc.)
  #   networkPolicyEnforcer - handle with `cnpCrdRef` (Phase A)
  #
  # Returns { cnps = [resource]; edges = [edge]; } where edges feed the
  # cluster-level inverted-ingress pass.
  buildWorkloadCnps =
    {
      scope,
      instanceName,
      namespaceName,
      workloadInput,
      workloadKind,
      wSelector,
      hostNetwork,
      serviceRegistry,
      networkConfig,
      packageNetworkMeta ? { },
      networkPolicyEnforcer ? null,
    }:
    let
      directions = networkConfig.directions or "both";
      doEgress = directions == "both" || directions == "egress";
      doIngress = directions == "both" || directions == "ingress";
      networkMeta = packageNetworkMeta;

      # Extract service edges directly from the raw args' JSON context —
      # no throw-away preliminary resource, no second `builtins.toFile`.
      edges = extractServiceEdgesFromJson {
        json = builtins.toJSON workloadInput;
        inherit serviceRegistry;
      };

      serviceRules = map (
        edge:
        let
          sel =
            if edge.targetNamespace == namespaceName then
              edge.targetSelector
            else
              edge.targetSelector
              // {
                "k8s:io.kubernetes.pod.namespace" = edge.targetNamespace;
              };
          cp = portsToCilium edge.ports;
        in
        {
          toEndpoints = [ { matchLabels = sel; } ];
        }
        // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; }
      ) edges;

      selfEgress = lib.optional (workloadKind == "StatefulSet") {
        toEndpoints = [ { matchLabels = wSelector; } ];
      };

      egressRules = [
        dnsEgressRule
      ]
      ++ serviceRules
      ++ selfEgress
      ++ lib.optional (networkMeta.allowExternalEgress or false) {
        toEntities = networkMeta.externalEgressEntities or [ "world" ];
      }
      ++ (networkMeta.extraEgress or [ ]);

      selfIngress = lib.optional (workloadKind == "StatefulSet") {
        fromEndpoints = [ { matchLabels = wSelector; } ];
      };

      ingressRules = selfIngress ++ (networkMeta.extraIngress or [ ]);

      # The workload name isn't stamped yet (workloadInput.name is the
      # user's chosen name, pre-sanitization). Use it verbatim for the CNP
      # name — same shape as `processInstance`'s old egress/ingress names.
      wName = workloadInput.name or (throw "buildWorkloadCnps: workloadInput.name is required");

      # Service refs go into the CNP's extraDeps so the CNP waits for its
      # referenced services to exist before it's applied. NOTE: we do NOT
      # put the workload in the CNP's extraDeps (that would create a cycle
      # once `mkWorkload` puts the CNP in the workload's extraDeps).
      serviceDeps = map (e: e.service) edges;

      egressCnp =
        if hostNetwork || !doEgress then
          null
        else
          buildCnp {
            inherit networkPolicyEnforcer;
            mkResource = scope.mkResource;
            extraArgs = {
              name = "${instanceName}-${lib.toLower workloadKind}-${wName}-egress";
              labels = {
                "kix.dev/derived" = "true";
              };
              spec = {
                endpointSelector.matchLabels = wSelector;
                egress = egressRules;
              };
              extraDeps = serviceDeps;
            };
          };

      ingressCnp =
        if hostNetwork || !doIngress || ingressRules == [ ] then
          null
        else
          buildCnp {
            inherit networkPolicyEnforcer;
            mkResource = scope.mkResource;
            extraArgs = {
              name = "${instanceName}-${lib.toLower workloadKind}-${wName}-ingress";
              labels = {
                "kix.dev/derived" = "true";
              };
              spec = {
                endpointSelector.matchLabels = wSelector;
                ingress = ingressRules;
              };
              extraDeps = [ ];
            };
          };

      # ── Caller-side inverted-ingress emission (v2_discussions/83 Phase C) ──
      #
      # For each discovered cross-package egress edge, emit a paired ingress
      # CNP in the *callee's* namespace via `scope.forNamespace`. The CNP's
      # endpointSelector matches the target Service's pod selector; its
      # fromEndpoints stamps the caller's selector plus
      # `k8s:io.kubernetes.pod.namespace = <callerNs>`.
      #
      # Both CNPs (egress + paired ingress) land in the caller workload's
      # `extraDeps` below, so the caller's readiness gate includes its
      # ingress grant at the callee. `scope.forNamespace` preserves
      # `instanceName` (see `scope.nix`), so the emitted CNP carries
      # `app.kubernetes.io/instance = <caller>` — caller owns the grant.
      #
      # This replaces the old cluster-level `generateIngressPolicies` pass.
      # The audit in `scripts/netpol-edge-audit.nix` verifies that the
      # scope-time edge set equals the post-fixpoint edge set on every
      # fixture cluster (zero misses on 12 clusters / 76 instances).
      callerIngressCnps =
        if hostNetwork || !doIngress then
          [ ]
        else
          map (
            edge:
            let
              targetScope = scope.forNamespace edge.targetNamespace;
              fromEndpoint = {
                matchLabels = wSelector // {
                  "k8s:io.kubernetes.pod.namespace" = namespaceName;
                };
              };
              cp = portsToCilium edge.ports;
              ingressRule = {
                fromEndpoints = [ fromEndpoint ];
              }
              // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };
            in
            buildCnp {
              inherit networkPolicyEnforcer;
              mkResource = targetScope.mkResource;
              extraArgs = {
                name = "${instanceName}-${lib.toLower workloadKind}-${wName}-to-${edge.service.name}-ingress";
                labels = {
                  "kix.dev/derived" = "true";
                  "kix.dev/policy-type" = "caller-ingress";
                };
                spec = {
                  endpointSelector.matchLabels = edge.targetSelector;
                  ingress = [ ingressRule ];
                };
                extraDeps = [ edge.service ];
              };
            }
          ) edges;

    in
    {
      cnps = builtins.filter (c: c != null) (
        [
          egressCnp
          ingressCnp
        ]
        ++ callerIngressCnps
      );
    };

  # ── Per-instance processing (post-fixpoint supplements) ───────────────
  #
  # Called from evaluateInstance after closure computation. The bulk of
  # per-workload CNP emission (DNS + cross-package service egress + self-
  # ingress for StatefulSets + meta.network extras) has moved into
  # `scope.mkDeployment` via `buildWorkloadCnps`, so the workload's own
  # store-path context carries its CNPs before `builtins.toFile` runs
  # (see v2_discussions/83).
  #
  # What stays here:
  #   - **Warnings**: hostNetwork, helm opacity.
  #   - **Precise api-server egress**: emitted only for workloads whose
  #     ServiceAccount is the subject of some Role/ClusterRoleBinding in
  #     the instance closure. Requires the instance view because the
  #     binding is typically a sibling resource of the workload, not part
  #     of its own manifest. Replaces the old "any RBAC in the instance
  #     → grant apiserver to every non-hostnet workload" heuristic.
  #   - **External-ingress supplement** for LoadBalancer Services only.
  #     hostNetwork is no longer a trigger: the old behavior granted
  #     world-ingress to *sibling* workloads of a hostNetwork pod, and
  #     hostNetwork pods themselves can't be gated by CiliumNetworkPolicy.
  #     Narrowing to just LB-backing pods requires a `mkService` hook —
  #     see v2_discussions/85.
  #
  # Inverted cross-package ingress is now emitted caller-side inside
  # `buildWorkloadCnps` via `scope.forNamespace` (v2_discussions/83
  # Phase C), so there is no `edges` sideband to thread through here —
  # this function no longer participates in the ingress derivation at
  # all.
  #
  # Returns { policies = [resource]; warnings = [string]; }
  processInstance =
    {
      scope,
      instanceName,
      allPartResources,
      networkConfig,
      packageMeta,
      # Handle to the cluster-level network-policy enforcer's `out`
      # (see kix/lib/eval/cluster.nix → enforcerOut). When non-null, every
      # emitted CNP is routed through `cnpCrdRef.out.cr` to pick up the
      # CRD marker → enforcer root edge.
      networkPolicyEnforcer ? null,
    }:
    let
      directions = networkConfig.directions or "both";
      doEgress = directions == "both" || directions == "egress";
      doIngress = directions == "both" || directions == "ingress";

      workloads = builtins.filter isWorkload allPartResources;

      hostNetworkWorkloads = builtins.filter (
        w: w.rawManifest.spec.template.spec.hostNetwork or false
      ) workloads;

      # --- Precise apiserver detection via SA → Binding walk ---
      #
      # A workload needs apiserver egress iff its ServiceAccount is the
      # subject of some Role/ClusterRoleBinding in the instance closure.
      # The old heuristic ("any RBAC/CRD in the instance → every non-
      # hostnet workload gets apiserver egress") over-granted to sibling
      # workloads that didn't bind apiserver-accessing SAs.

      bindings = builtins.filter (
        r:
        builtins.elem (r.kind or "") [
          "RoleBinding"
          "ClusterRoleBinding"
        ]
      ) allPartResources;

      # Set of "<ns>/<saName>" keys for ServiceAccounts bound to some
      # Role or ClusterRole. RoleBinding subjects default to the binding's
      # namespace when unset; ClusterRoleBinding subjects must name an
      # explicit namespace (dropped if missing).
      boundSAKeys = builtins.concatMap (
        b:
        let
          subjects = b.rawManifest.subjects or [ ];
          bindingNs = b.rawManifest.metadata.namespace or null;
        in
        builtins.filter (k: k != null) (
          map (
            s:
            if (s.kind or "") == "ServiceAccount" then
              let
                ns = s.namespace or bindingNs;
                saName = s.name or null;
              in
              if ns == null || saName == null then null else "${ns}/${saName}"
            else
              null
          ) subjects
        )
      ) bindings;

      workloadNeedsApiserver =
        w:
        let
          saName = w.rawManifest.spec.template.spec.serviceAccountName or "default";
          wNs = w.rawManifest.metadata.namespace or null;
        in
        wNs != null && builtins.elem "${wNs}/${saName}" boundSAKeys;

      # External ingress is triggered only by LoadBalancer Services.
      # hostNetwork was previously a trigger but its semantics were
      # broken: it granted world-ingress to *sibling* workloads of a
      # hostNetwork pod rather than to the hostNetwork pod itself (which
      # CNPs can't gate anyway). See v2_discussions/85.
      needsExternalIngress = builtins.any (
        r: isService r && (r.rawManifest.spec.type or "") == "LoadBalancer"
      ) allPartResources;

      # --- Supplementary api-server / external-ingress CNPs ---
      #
      # Per-workload CNPs for DNS + cross-package service egress + self-
      # communication (StatefulSet) are now emitted at `scope.mkDeployment`
      # time and live in `_generatedNetpol` on each workload. processInstance
      # only adds the supplementary rules whose signals require the full
      # instance closure: api-server access (derived from RBAC/CRD presence)
      # and external ingress (derived from LoadBalancer Services / hostNetwork
      # workloads). These CNPs depend on the workload (not the other way
      # around) — additive permission grants, not readiness gates.

      apiServerSupplementPolicies =
        if !doEgress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = w.rawManifest.spec.selector.matchLabels or { };
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;
            in
            if isHostNet || !(workloadNeedsApiserver w) then
              [ ]
            else
              [
                (buildCnp {
                  inherit networkPolicyEnforcer;
                  mkResource = scope.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-apiserver-egress";
                    labels = {
                      "kix.dev/derived" = "true";
                      "kix.dev/policy-type" = "apiserver-supplement";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      egress = [ apiServerEgressRule ];
                    };
                    extraDeps = [ w ];
                  };
                })
              ]
          ) workloads;

      externalIngressSupplementPolicies =
        if !doIngress || !needsExternalIngress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = w.rawManifest.spec.selector.matchLabels or { };
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;
            in
            if isHostNet then
              [ ]
            else
              [
                (buildCnp {
                  inherit networkPolicyEnforcer;
                  mkResource = scope.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-external-ingress";
                    labels = {
                      "kix.dev/derived" = "true";
                      "kix.dev/policy-type" = "external-ingress-supplement";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      ingress = [
                        { fromEntities = packageMeta.network.externalIngressEntities or [ "world" ]; }
                      ];
                    };
                    extraDeps = [ w ];
                  };
                })
              ]
          ) workloads;

      # --- Warnings ---

      warnings =
        map (
          w:
          "[${instanceName}] workload '${w.kind}/${w.name}' uses hostNetwork — CiliumNetworkPolicy has no effect"
        ) hostNetworkWorkloads
        ++
          lib.optional (packageMeta.isHelm or false)
            "[${instanceName}] Helm-wrapped package: intra-package network policies may be incomplete — review or add manual policies";

    in
    {
      policies = apiServerSupplementPolicies ++ externalIngressSupplementPolicies;
      inherit warnings;
    };

  # ── Default deny per namespace ────────────────────────────────────────
  #
  # Respects `directions`: only denies the directions being enforced.
  generateDefaultDeny =
    {
      namespaceName,
      nsResource,
      directions,
      networkPolicyEnforcer ? null,
    }:
    let
      denyIngress = directions == "both" || directions == "ingress";
      denyEgress = directions == "both" || directions == "egress";
    in
    buildCnp {
      inherit networkPolicyEnforcer;
      mkResource = k8s.mkResource;
      extraArgs = {
        name = "${namespaceName}-default-deny";
        namespace = nsResource;
        labels = {
          "kix.dev/derived" = "true";
          "kix.dev/policy-type" = "default-deny";
          "app.kubernetes.io/managed-by" = "kix";
        };
        spec = {
          endpointSelector = { };
        }
        // lib.optionalAttrs denyIngress { ingress = [ ]; }
        // lib.optionalAttrs denyEgress { egress = [ ]; };
      };
    };
}
