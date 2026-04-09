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
  helpers,
}:

let
  inherit (helpers) collectTypedAttrs;

  # Build a CiliumNetworkPolicy, routing through the enforcer's
  # `cnpCrdRef.out.cr` when an enforcer is available. That builder stamps
  # `apiVersion`/`kind` and adds the CRD import marker to `requires`, so
  # every CNP transitively depends on the enforcer's root (via the marker's
  # `installedBy`). When no enforcer is declared (e.g. cilium runs
  # out-of-band on the cluster) we fall back to emitting the CNP directly
  # via the caller's mkResource — the store-path edge to the enforcer is
  # lost but the CNP is still generated.
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
    let
      baseArgs = extraArgs // {
        apiVersion = "cilium.io/v2";
        kind = "CiliumNetworkPolicy";
      };
    in
    if networkPolicyEnforcer != null && networkPolicyEnforcer.cnpCrdRef or null != null then
      mkResource (
        networkPolicyEnforcer.cnpCrdRef.out.cr (
          removeAttrs baseArgs [
            "apiVersion"
            "kind"
          ]
        )
      )
    else
      mkResource baseArgs;

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

  # Extract Service edges from a workload (built resource) via store-path context.
  extractServiceEdges =
    { workload, serviceRegistry }:
    extractServiceEdgesFromJson {
      json = builtins.toJSON workload.rawManifest;
      inherit serviceRegistry;
    };

  # Same as `extractServiceEdges` but operating on a pre-built JSON string.
  # Used by `buildWorkloadCnps` which runs inside `scope.mkDeployment` —
  # before the workload resource exists — and extracts edges directly from
  # the caller's args JSON. The store-path context on the JSON is identical
  # to what the built `rawManifest` would carry (same input attrs), so this
  # is a strictly equivalent path that avoids a throw-away `mkResource` call.
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

      flattenedEdges = map (edge: {
        sourceSelector = wSelector;
        sourceNamespace = namespaceName;
        inherit (edge)
          service
          ports
          targetSelector
          targetNamespace
          ;
      }) edges;

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

    in
    {
      cnps = builtins.filter (c: c != null) [
        egressCnp
        ingressCnp
      ];
      edges = flattenedEdges;
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
  #   - **Supplementary CNPs** that depend on post-fixpoint signals
  #     (api-server access derived from RBAC/CRD presence across the
  #     whole instance; external-ingress derived from LoadBalancer Service
  #     or hostNetwork workloads). These are additive permissions, not
  #     gating policies — they depend on the workload the old way
  #     (CNP → workload), which is fine.
  #   - **Edges** for the cluster-level inverted-ingress pass. Same
  #     extraction as before, run against `allPartResources`.
  #
  # Returns { policies = [resource]; edges = [edge]; warnings = [string]; }
  processInstance =
    {
      scope,
      instanceName,
      namespaceName,
      allPartResources,
      resolvedDepMeta,
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
      networkMeta = packageMeta.network or { };

      workloads = builtins.filter isWorkload allPartResources;

      # --- Signal detection (derived from resource graph, no meta needed) ---

      needsApiServerAccess = builtins.any (
        r:
        builtins.elem (r.kind or "") [
          "ClusterRole"
          "ClusterRoleBinding"
          "Role"
          "RoleBinding"
          "CustomResourceDefinition"
        ]
      ) allPartResources;

      needsExternalIngress = builtins.any (
        r:
        (isService r && (r.rawManifest.spec.type or "") == "LoadBalancer")
        || (isWorkload r && (r.rawManifest.spec.template.spec.hostNetwork or false))
      ) allPartResources;

      hostNetworkWorkloads = builtins.filter (
        w: w.rawManifest.spec.template.spec.hostNetwork or false
      ) workloads;

      # --- Build service registry (local + dep services) ---

      depResources = builtins.concatMap (
        argName:
        let
          depParts = resolvedDepMeta.${argName}.instance.raw or { };
        in
        builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "root"
              "meta"
            ];
          } depParts
        )
      ) (builtins.attrNames resolvedDepMeta);

      serviceRegistry = mkServiceRegistry (allPartResources ++ depResources);

      # --- Per-workload edge extraction ---

      workloadEdges = map (w: {
        workload = w;
        edges = extractServiceEdges {
          workload = w;
          inherit serviceRegistry;
        };
      }) workloads;

      # Flatten for cluster-level ingress pass.
      allEdges = builtins.concatMap (
        we:
        map (edge: {
          sourceSelector = we.workload.rawManifest.spec.selector.matchLabels or { };
          sourceNamespace = namespaceName;
          inherit (edge)
            service
            ports
            targetSelector
            targetNamespace
            ;
        }) we.edges
      ) workloadEdges;

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
        if !doEgress || !needsApiServerAccess then
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
                        { fromEntities = networkMeta.externalIngressEntities or [ "world" ]; }
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
      edges = allEdges;
      inherit warnings;
    };

  # ── Cluster-level ingress pass ────────────────────────────────────────
  #
  # Inverts egress edges: for each target Service, generates an ingress
  # CiliumNetworkPolicy allowing traffic from the source workloads.
  generateIngressPolicies =
    {
      allEdges,
      nsResources,
      networkConfig,
      networkPolicyEnforcer ? null,
    }:
    let
      directions = networkConfig.directions or "both";
      doIngress = directions == "both" || directions == "ingress";
    in
    if !doIngress || allEdges == [ ] then
      [ ]
    else
      let
        # Group edges by target Service (store path as key).
        grouped = builtins.foldl' (
          acc: edge:
          let
            key = builtins.unsafeDiscardStringContext edge.service.outPath;
          in
          acc
          // {
            ${key} = {
              inherit (edge)
                service
                targetSelector
                targetNamespace
                ports
                ;
              sources = (acc.${key}.sources or [ ]) ++ [
                {
                  selector = edge.sourceSelector;
                  namespace = edge.sourceNamespace;
                }
              ];
            };
          }
        ) { } allEdges;
      in
      builtins.concatMap (
        key:
        let
          entry = grouped.${key};
          nsRes = nsResources.${entry.targetNamespace} or null;
          cp = portsToCilium entry.ports;

          fromEndpoints = map (src: {
            matchLabels =
              if src.namespace == entry.targetNamespace then
                src.selector
              else
                src.selector
                // {
                  "k8s:io.kubernetes.pod.namespace" = src.namespace;
                };
          }) entry.sources;

          ingressRule = {
            inherit fromEndpoints;
          }
          // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };
        in
        if nsRes == null || entry.targetSelector == { } then
          [ ]
        else
          [
            (buildCnp {
              inherit networkPolicyEnforcer;
              mkResource = k8s.mkResource;
              extraArgs = {
                name = "${entry.service.name}-ingress";
                namespace = nsRes;
                labels = {
                  "kix.dev/derived" = "true";
                  "kix.dev/policy-type" = "ingress";
                  "app.kubernetes.io/managed-by" = "kix";
                };
                spec = {
                  endpointSelector.matchLabels = entry.targetSelector;
                  ingress = [ ingressRule ];
                };
                extraDeps = [ entry.service ];
              };
            })
          ]
      ) (builtins.attrNames grouped);

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
