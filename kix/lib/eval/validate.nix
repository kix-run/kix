# Cross-resource integrity checks over a cluster's finished manifests.
#
# `crossResourceFailures { manifests, externalNames ? { } }` returns a list
# of human-readable failure strings (empty when the set is consistent).
# `externalNames` is the set of "<namespace>/<name>" keys packages marked
# with `kix.untrackedRef`: buildCluster collects them from string context
# before it is stripped, so a reference the author declared external
# resolves. Import markers in the manifest set (PackageInstance with
# `kix.dev/import-kind` and `kix.dev/import-name`, from
# scope.mkServiceRef/mkSecretRef) count as the object they stand for in
# the lookups, and a ref's declared pod selector stands in for a pod
# template in the selector checks. buildCluster feeds the failure list
# into the cluster diagnostics, so every cluster evaluation runs these
# checks: `nix build`, and every `kix` command that evaluates a cluster
# (`kix drift`, `kix rollback` and `completions` do not). `kix/checks.nix`
# re-exports the throwing form for `nix flake check`; that path can no
# longer fail on its own, since the eval it reads asserts first.
#
# These are RESOLUTION checks: does the thing a name points at exist, do
# these labels really match a pod in the build. They complement the
# scorecard rules in kix/lib/rules/, which check PROVENANCE (did a value
# come from a workload) while string context is still attached. The
# manifests here have that context stripped, so a check that needs to
# know where a value came from cannot live in this file.
#
# History and audit: v2_discussions/135 (kixpkgs#70).
#
# Design principles:
#   - Every failure names the specific resource(s) involved.
#   - External references (cluster-provided roles, system pods) are
#     exempted via documented allowlists.
#   - Only INTERNAL references (resources created by kix) are validated.

{ lib }:

rec {
  crossResourceFailures =
    {
      manifests,
      externalNames ? { },
    }:
    let
      resources = manifests;

      # --- Helpers ---

      # Resource identity: kind/namespace/name (unique within a cluster).
      resourceId =
        r:
        let
          ns = r.metadata.namespace or "cluster-scoped";
          name = r.metadata.name or "unnamed";
        in
        "${r.kind}/${ns}/${name}";

      # Index by (kind, namespace, name) for namespace-aware lookup.
      byId = builtins.foldl' (acc: r: acc // { "${resourceId r}" = r; }) { } resources;

      # Import markers stand in for objects kix does not render: a
      # PackageInstance carrying kix.dev/import-kind and kix.dev/import-name
      # (scope.mkServiceRef, scope.mkSecretRef, mkImportMarker). The deploy
      # engine gates on the described object, so a reference to it resolves.
      importIds = builtins.listToAttrs (
        builtins.concatMap (
          r:
          let
            anns = r.metadata.annotations or { };
            kind = anns."kix.dev/import-kind" or null;
            iname = anns."kix.dev/import-name" or null;
            ns = r.metadata.namespace or "cluster-scoped";
          in
          if r.kind == "PackageInstance" && kind != null && iname != null then
            [
              {
                name = "${kind}/${ns}/${iname}";
                value = true;
              }
            ]
          else
            [ ]
        ) resources
      );

      # Cluster-scoped resources (Namespace, ClusterRole, etc.) have no namespace.
      # Namespace-scoped lookups need the referring resource's namespace.
      # A name the author wrapped in `kix.untrackedRef` is external by
      # declaration and resolves whatever its kind.
      hasResource =
        kind: ns: name:
        byId ? "${kind}/${ns}/${name}"
        || byId ? "${kind}/cluster-scoped/${name}"
        || importIds ? "${kind}/${ns}/${name}"
        || externalNames ? "${ns}/${name}"
        || externalNames ? "cluster-scoped/${name}";

      # Pod selectors declared by ServiceRef markers (kix.dev/service-selector):
      # the operator's pods exist by declaration, so a Service or
      # NetworkPolicy in the same namespace whose selector is within one
      # of them selects real pods. A witness for checks 4 and 12, which
      # otherwise only see pod templates in the build.
      refPodSelectors = builtins.concatMap (
        r:
        let
          anns = r.metadata.annotations or { };
        in
        if r.kind == "PackageInstance" && anns ? "kix.dev/service-selector" then
          [
            {
              ns = r.metadata.namespace or "cluster-scoped";
              labels = builtins.fromJSON anns."kix.dev/service-selector";
            }
          ]
        else
          [ ]
      ) resources;
      selectsRefPods =
        ns: selector:
        builtins.any (w: w.ns == ns && selectorMatchesLabels selector w.labels) refPodSelectors;

      workloadKinds = [
        "Deployment"
        "StatefulSet"
        "DaemonSet"
        "Job"
        "CronJob"
      ];
      workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

      getPodSpec =
        r:
        let
          template =
            if r.kind == "CronJob" then
              r.spec.jobTemplate.spec.template.spec or { }
            else
              r.spec.template.spec or { };
        in
        template;

      # Pod template labels, CronJob-aware like getPodSpec. Checks 4, 12 and
      # 13 match selectors against these; reading spec.template directly
      # made CronJob pods invisible to them.
      getPodLabels =
        r:
        if r.kind == "CronJob" then
          r.spec.jobTemplate.spec.template.metadata.labels or { }
        else
          r.spec.template.metadata.labels or { };

      selectorMatchesLabels =
        selector: labels: builtins.all (k: (labels.${k} or null) == selector.${k}) (lib.attrNames selector);

      # --- Allowlists for external references ---

      # Roles provided by the cluster itself, not by kix.
      externalRoleRef =
        name:
        lib.hasPrefix "system:" name
        || lib.hasSuffix "-psp" name
        || builtins.elem name [
          "admin"
          "cluster-admin"
          "edit"
          "view"
        ];

      # A Service kix renders over pods an operator creates at runtime has no
      # pod template to match. The package says so on the Service:
      #   metadata.annotations."kix.dev/operand-of" = "<group>/<Kind>/<name>"
      # names the CR whose operand pods it selects, and check 4 accepts it
      # when that CR is in the build in the same namespace. Keyed by group
      # and kind: kind names alone are not unique across API groups. This
      # replaced a global list of operator kinds plus a name-prefix guess
      # (v2_discussions/135, kixpkgs#70). Where the operator creates the
      # Service itself, scope.mkServiceRef is the better tool: nothing to
      # exempt.
      operandOfAnnotation = "kix.dev/operand-of";
      # "monitoring.coreos.com/v1" -> "monitoring.coreos.com"; the core group
      # ("v1") is "", as Kubernetes writes it.
      groupOf =
        apiVersion:
        let
          parts = lib.splitString "/" apiVersion;
        in
        if builtins.length parts == 2 then builtins.head parts else "";
      crIds = builtins.listToAttrs (
        map (r: {
          name = "${groupOf (r.apiVersion or "")}/${r.kind}/${
            r.metadata.namespace or "cluster-scoped"
          }/${r.metadata.name or "unnamed"}";
          value = true;
        }) resources
      );
      operandOf = svc: (svc.metadata.annotations or { }).${operandOfAnnotation} or null;
      operandCrPresent =
        svc:
        let
          decl = operandOf svc;
          parts = if decl == null then [ ] else lib.splitString "/" decl;
          ns = svc.metadata.namespace or "cluster-scoped";
        in
        builtins.length parts == 3
        && crIds ? "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}/${ns}/${builtins.elemAt parts 2}";

      systemComponentSelectors = [
        { "k8s-app" = "kube-dns"; }
        { "k8s-app" = "coredns"; }
        { "component" = "kube-controller-manager"; }
        { "component" = "kube-scheduler"; }
        { "component" = "kube-apiserver"; }
        { "k8s-app" = "kube-proxy"; }
        { "component" = "etcd"; }
      ];

      isExemptService =
        svc:
        let
          selector = svc.spec.selector or { };
        in
        # No selector — headless or external-name service.
        selector == { }
        # Targets a K8s system component (metrics scraping).
        || builtins.any (sc: selectorMatchesLabels sc selector) systemComponentSelectors
        # Declares the CR whose operand pods it selects, and that CR is here.
        || operandCrPresent svc;

      # --- 1. ServiceAccount references ---

      saFailures = builtins.concatMap (
        w:
        let
          podSpec = getPodSpec w;
          saName = podSpec.serviceAccountName or null;
          ns = w.metadata.namespace or "cluster-scoped";
        in
        if saName == null || saName == "default" then
          [ ]
        else if hasResource "ServiceAccount" ns saName then
          [ ]
        else
          [ "${w.kind} ${ns}/${w.metadata.name} references ServiceAccount '${saName}' which does not exist" ]
      ) workloads;

      # --- 2. RoleBinding/ClusterRoleBinding roleRef ---

      roleRefFailures =
        builtins.concatMap
          (
            binding:
            let
              ref = binding.roleRef or { };
              refKind = ref.kind or "";
              refName = ref.name or "";
              ns = binding.metadata.namespace or "cluster-scoped";
            in
            if hasResource refKind ns refName || externalRoleRef refName then
              [ ]
            else
              [
                "${binding.kind} ${ns}/${binding.metadata.name} references ${refKind} '${refName}' which does not exist"
              ]
          )
          (
            builtins.filter (
              r:
              builtins.elem r.kind [
                "RoleBinding"
                "ClusterRoleBinding"
              ]
            ) resources
          );

      # --- 3. ConfigMap volume references ---
      # Secrets are intentionally not checked — they are commonly managed
      # externally (Infisical, sealed-secrets, manual creation).

      volumeRefFailures = builtins.concatMap (
        w:
        let
          podSpec = getPodSpec w;
          volumes =
            let
              v = podSpec.volumes or [ ];
            in
            if v == null then [ ] else v;
          ns = w.metadata.namespace or "cluster-scoped";
        in
        builtins.concatMap (
          vol:
          let
            cmName = vol.configMap.name or null;
          in
          if cmName != null && !(hasResource "ConfigMap" ns cmName) then
            [
              "${w.kind} ${ns}/${w.metadata.name} mounts ConfigMap '${cmName}' which does not exist"
            ]
          else
            [ ]
        ) volumes
      ) workloads;

      # --- 4. Service selector -> workload label matching ---

      serviceFailures = builtins.concatMap (
        svc:
        if isExemptService svc then
          [ ]
        else
          let
            selector = svc.spec.selector or { };
            ns = svc.metadata.namespace or "cluster-scoped";
            matchesAny =
              builtins.any (w: selectorMatchesLabels selector (getPodLabels w)) workloads
              || selectsRefPods ns selector;
          in
          if matchesAny then
            [ ]
          else if operandOf svc != null && builtins.length (lib.splitString "/" (operandOf svc)) != 3 then
            [
              "Service ${ns}/${svc.metadata.name} declares ${operandOfAnnotation}=${operandOf svc}, which is not of the form <group>/<Kind>/<name>"
            ]
          else if operandOf svc != null then
            [
              "Service ${ns}/${svc.metadata.name} declares ${operandOfAnnotation}=${operandOf svc} but no such CR is in the build in namespace ${ns}"
            ]
          else
            [
              "Service ${ns}/${svc.metadata.name} selector ${builtins.toJSON selector} matches no workload pod template"
            ]
      ) (builtins.filter (r: r.kind == "Service") resources);

      # --- 5. HPA scaleTargetRef ---

      hpaFailures = builtins.concatMap (
        hpa:
        let
          ref = hpa.spec.scaleTargetRef or { };
          refKind = ref.kind or "";
          refName = ref.name or "";
          ns = hpa.metadata.namespace or "cluster-scoped";
        in
        if hasResource refKind ns refName then
          [ ]
        else
          [
            "HorizontalPodAutoscaler ${ns}/${hpa.metadata.name} targets ${refKind} '${refName}' which does not exist"
          ]
      ) (builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources);

      # --- 6. StatefulSet serviceName → headless Service validation ---
      # spec.serviceName must match a headless Service (clusterIP: None) in the
      # same namespace. A mismatch silently breaks per-pod DNS identity.
      serviceNameFailures =
        let
          headlessServiceNames = builtins.listToAttrs (
            builtins.concatMap (
              r:
              if r.kind == "Service" && (r.spec.clusterIP or "") == "None" then
                [
                  {
                    name = "${r.metadata.namespace or "cluster-scoped"}/${r.metadata.name}";
                    value = true;
                  }
                ]
              else
                [ ]
            ) resources
          );
        in
        builtins.concatMap (
          sts:
          let
            svcName = sts.spec.serviceName or null;
            ns = sts.metadata.namespace or "cluster-scoped";
          in
          if svcName == null || headlessServiceNames ? "${ns}/${svcName}" then
            [ ]
          else
            [
              "StatefulSet ${ns}/${sts.metadata.name} serviceName '${svcName}' does not match any headless Service (clusterIP: None) in the same namespace"
            ]
        ) (builtins.filter (r: r.kind == "StatefulSet") resources);

      # --- 7. No duplicate (kind, namespace, name) tuples ---

      resourceIds = map resourceId resources;
      uniqueIds = lib.unique resourceIds;
      duplicateFailures =
        if builtins.length resourceIds == builtins.length uniqueIds then
          [ ]
        else
          let
            counts = builtins.foldl' (acc: id: acc // { ${id} = (acc.${id} or 0) + 1; }) { } resourceIds;
            dups = lib.filterAttrs (_: c: c > 1) counts;
          in
          map (id: "Duplicate resource: ${id}") (lib.attrNames dups);

      # --- 8. managed-by label ---

      managedByFailures = builtins.concatMap (
        r:
        if (r.metadata.labels."app.kubernetes.io/managed-by" or "") == "kix" then
          [ ]
        else
          [ "${r.kind} ${resourceId r} is missing app.kubernetes.io/managed-by=kix label" ]
      ) resources;

      # --- 9. Selector consistency ---
      # A workload's spec.selector.matchLabels must be a subset of its
      # pod template labels, otherwise the workload will never match its pods.

      selectorConsistencyFailures =
        builtins.concatMap
          (
            w:
            let
              selectorLabels = w.spec.selector.matchLabels or { };
              templateLabels = w.spec.template.metadata.labels or { };
              ns = w.metadata.namespace or "cluster-scoped";
            in
            if selectorLabels == { } then
              [ ]
            else if selectorMatchesLabels selectorLabels templateLabels then
              [ ]
            else
              [
                "${w.kind} ${ns}/${w.metadata.name} selector ${builtins.toJSON selectorLabels} is not a subset of pod template labels ${builtins.toJSON templateLabels}"
              ]
          )
          (
            builtins.filter (
              r:
              builtins.elem r.kind [
                "Deployment"
                "StatefulSet"
                "DaemonSet"
              ]
            ) resources
          );

      # --- 10. Ingress backend Service references ---
      # Every Ingress backend must reference a Service that exists in the same namespace.

      ingressFailures = builtins.concatMap (
        ing:
        let
          ns = ing.metadata.namespace or "cluster-scoped";
          # Collect all backend service names from rules and defaultBackend.
          ruleBackends = builtins.concatMap (
            rule:
            builtins.concatMap (
              path:
              let
                svcName = path.backend.service.name or null;
              in
              if svcName != null then [ svcName ] else [ ]
            ) (rule.http.paths or [ ])
          ) (ing.spec.rules or [ ]);
          defaultBackend =
            let
              svcName = ing.spec.defaultBackend.service.name or null;
            in
            if svcName != null then [ svcName ] else [ ];
          allBackends = lib.unique (ruleBackends ++ defaultBackend);
        in
        builtins.concatMap (
          svcName:
          if hasResource "Service" ns svcName then
            [ ]
          else
            [ "Ingress ${ns}/${ing.metadata.name} references Service '${svcName}' which does not exist" ]
        ) allBackends
      ) (builtins.filter (r: r.kind == "Ingress") resources);

      # --- 11. Namespace existence ---
      # Every namespaced resource must have its Namespace in the manifest set.

      namespaceNames = builtins.listToAttrs (
        builtins.concatMap (
          r:
          if r.kind == "Namespace" then
            [
              {
                name = r.metadata.name;
                value = true;
              }
            ]
          else
            [ ]
        ) resources
      );

      # `_`-prefixed namespaces are kix's sentinel for cluster-level instances
      # (ROADMAP "Cluster-level instances"): eval keeps them out of Namespace
      # emission on purpose, so they are not missing, they are not real.
      isSentinelNamespace = ns: lib.hasPrefix "_" ns;

      # One failure per missing namespace, not one per resource in it.
      uniqueNamespaceFailures =
        let
          missingNs = lib.unique (
            builtins.concatMap (
              r:
              let
                ns = r.metadata.namespace or null;
              in
              if ns != null && !(isSentinelNamespace ns) && !(namespaceNames ? ${ns}) then [ ns ] else [ ]
            ) resources
          );
        in
        map (
          ns: "Namespace '${ns}' is referenced by resources but has no Namespace resource in the manifest set"
        ) missingNs;

      # --- 12. NetworkPolicy podSelector matching ---
      # A NetworkPolicy's podSelector should match at least one workload's pod
      # template labels. An unmatched NetworkPolicy is dead config.

      networkPolicyFailures = builtins.concatMap (
        np:
        let
          selector = np.spec.podSelector.matchLabels or { };
          ns = np.metadata.namespace or "cluster-scoped";
        in
        # Empty selector matches all pods in the namespace — always valid.
        if selector == { } then
          [ ]
        else if
          builtins.any (w: selectorMatchesLabels selector (getPodLabels w)) workloads
          || selectsRefPods ns selector
        then
          [ ]
        else
          [
            "NetworkPolicy ${ns}/${np.metadata.name} podSelector ${builtins.toJSON selector} matches no workload pod template"
          ]
      ) (builtins.filter (r: r.kind == "NetworkPolicy") resources);

      # --- 13. Service port name → container port name consistency ---
      # When a Service uses a named targetPort, that port name must exist in
      # at least one matched workload's container ports.

      portNameFailures = builtins.concatMap (
        svc:
        let
          selector = svc.spec.selector or { };
          ns = svc.metadata.namespace or "cluster-scoped";
          svcPorts = svc.spec.ports or [ ];
          # Named targetPorts (skip numeric ones).
          namedTargetPorts = builtins.filter (
            p:
            let
              tp = p.targetPort or null;
            in
            tp != null && builtins.isString tp
          ) svcPorts;
          # Find all container port names in matched workloads.
          matchedWorkloads = builtins.filter (w: selectorMatchesLabels selector (getPodLabels w)) workloads;
          containerPortNames = builtins.concatMap (
            w:
            builtins.concatMap (c: map (p: p.name or null) (c.ports or [ ])) ((getPodSpec w).containers or [ ])
          ) matchedWorkloads;
          portNameSet = builtins.listToAttrs (
            map (n: {
              name = n;
              value = true;
            }) (builtins.filter (n: n != null) containerPortNames)
          );
        in
        if selector == { } || namedTargetPorts == [ ] || matchedWorkloads == [ ] then
          [ ]
        else
          builtins.concatMap (
            p:
            let
              tp = p.targetPort;
            in
            if portNameSet ? ${tp} then
              [ ]
            else
              [
                "Service ${ns}/${svc.metadata.name} targetPort '${tp}' does not match any container port name in matched workloads"
              ]
          ) namedTargetPorts
      ) (builtins.filter (r: r.kind == "Service") resources);

      # --- Collect all failures ---

      allFailures =
        saFailures
        ++ roleRefFailures
        ++ volumeRefFailures
        ++ serviceFailures
        ++ hpaFailures
        ++ serviceNameFailures
        ++ duplicateFailures
        ++ managedByFailures
        ++ selectorConsistencyFailures
        ++ ingressFailures
        ++ uniqueNamespaceFailures
        ++ networkPolicyFailures
        ++ portNameFailures;
    in
    allFailures;

  # Throwing form, kept for `nix flake check` and the lithus monorepo, which
  # call it directly. Inside buildCluster the list form feeds the cluster
  # diagnostics instead (kix/lib/eval/cluster.nix).
  validateManifestSet =
    clusterName: manifests:
    let
      failures = crossResourceFailures { inherit manifests; };
    in
    if failures == [ ] then
      true
    else
      throw "validateManifestSet(${clusterName}):\n${
        lib.concatMapStringsSep "\n" (f: "  - ${f}") failures
      }";
}
