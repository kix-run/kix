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

  # Extract Service edges from a workload via store-path context.
  extractServiceEdges =
    { workload, serviceRegistry }:
    let
      ctx = builtins.getContext (builtins.toJSON workload.rawManifest);
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

  # ── Per-instance processing ───────────────────────────────────────────
  #
  # Called from evaluateInstance after closure computation.
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

      # --- Egress policies (per workload) ---

      egressPolicies =
        if !doEgress then
          [ ]
        else
          builtins.concatMap (
            we:
            let
              w = we.workload;
              wSelector = w.rawManifest.spec.selector.matchLabels or { };
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;
            in
            if isHostNet then
              [ ]
            else
              let
                # Egress to each referenced Service
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
                ) we.edges;

                # StatefulSet self-communication (all ports — covers discovery, replication, etc.)
                selfEgress = lib.optional (w.kind == "StatefulSet") {
                  toEndpoints = [ { matchLabels = wSelector; } ];
                };

                allRules = [
                  dnsEgressRule
                ]
                ++ serviceRules
                ++ selfEgress
                ++ lib.optional needsApiServerAccess apiServerEgressRule
                ++ lib.optional (networkMeta.allowExternalEgress or false) {
                  toEntities = [ "world" ];
                }
                ++ (networkMeta.extraEgress or [ ]);
              in
              [
                (scope.mkResource {
                  apiVersion = "cilium.io/v2";
                  kind = "CiliumNetworkPolicy";
                  name = "${instanceName}-${lib.toLower w.kind}-${w.name}-egress";
                  labels = {
                    "kix.dev/derived" = "true";
                  };
                  spec = {
                    endpointSelector.matchLabels = wSelector;
                    egress = allRules;
                  };
                  extraDeps = [ w ] ++ map (e: e.service) we.edges;
                })
              ]
          ) workloadEdges;

      # --- Instance-level ingress policies (external + self-communication) ---

      instanceIngressPolicies =
        if !doIngress then
          [ ]
        else
          builtins.concatMap (
            we:
            let
              w = we.workload;
              wSelector = w.rawManifest.spec.selector.matchLabels or { };
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;

              externalRules = lib.optional needsExternalIngress {
                fromEntities = [ "world" ];
              };

              selfIngress = lib.optional (w.kind == "StatefulSet") {
                fromEndpoints = [ { matchLabels = wSelector; } ];
              };

              allRules = externalRules ++ selfIngress ++ (networkMeta.extraIngress or [ ]);
            in
            if isHostNet || allRules == [ ] then
              [ ]
            else
              [
                (scope.mkResource {
                  apiVersion = "cilium.io/v2";
                  kind = "CiliumNetworkPolicy";
                  name = "${instanceName}-${lib.toLower w.kind}-${w.name}-ingress";
                  labels = {
                    "kix.dev/derived" = "true";
                  };
                  spec = {
                    endpointSelector.matchLabels = wSelector;
                    ingress = allRules;
                  };
                  extraDeps = [ w ];
                })
              ]
          ) workloadEdges;

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
      policies = egressPolicies ++ instanceIngressPolicies;
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
            (k8s.mkResource {
              apiVersion = "cilium.io/v2";
              kind = "CiliumNetworkPolicy";
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
    }:
    let
      denyIngress = directions == "both" || directions == "ingress";
      denyEgress = directions == "both" || directions == "egress";
    in
    k8s.mkResource {
      apiVersion = "cilium.io/v2";
      kind = "CiliumNetworkPolicy";
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
}
