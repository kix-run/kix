# Cross-resource integrity checks over a cluster's finished manifests.
#
# `crossResourceFailures { manifests, identityHashes, owners, externalNames }`
# returns a list of human-readable failure strings (empty when the set is
# consistent). `identityHashes` and `owners` are aligned with `manifests`:
# the store hash a resource's `kix.run/depends-on` entries name it by, and
# the "<namespace>/<instance>" of the instance that built it. Checks that
# follow dependencies (21) walk `kix.run/depends-on` through the hashes;
# messages name owners. `externalNames` is the set of "<namespace>/<name>"
# keys packages marked with `kix.untrackedRef`: buildCluster collects them
# from string context before it is stripped, so a reference the author
# declared external resolves. Import markers in the manifest set
# (PackageInstance with `kix.run/import-kind` and `kix.run/import-name`, from
# scope.mkServiceRef/mkSecretRef/mkCRDRef and kix.mkImport) count as the
# object they stand for in the lookups, and a ref's declared pod selector
# stands in for a pod template in the selector checks. buildCluster feeds
# the failure list into the cluster assertions, so every cluster evaluation
# runs these checks: `nix build`, and every `kix` command that evaluates a
# cluster (`kix drift`, `kix rollback` and `completions` do not).
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

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
in
rec {
  crossResourceFailures =
    {
      manifests,
      # Lists aligned with `manifests`. A null entry leaves that resource out
      # of dependency walks (check 21 then finds no declaration it depends
      # on) and unnamed in messages.
      identityHashes,
      owners,
      externalNames ? { },
    }:
    let
      resources = manifests;

      # --- Helpers ---

      entries = lib.imap0 (i: r: {
        inherit r;
        hash = builtins.elemAt identityHashes i;
        owner = builtins.elemAt owners i;
      }) resources;

      byHash = builtins.listToAttrs (
        map (e: {
          name = e.hash;
          value = e;
        }) (builtins.filter (e: e.hash != null) entries)
      );

      # "Deployment a/web" or "StorageClass fast": the namespace only when
      # the object has one.
      describe =
        r:
        let
          ns = r.metadata.namespace or null;
          name = r.metadata.name or "unnamed";
        in
        if ns == null then "${r.kind} ${name}" else "${r.kind} ${ns}/${name}";

      instanceClause = owner: if owner == null then "" else " (instance ${owner})";

      splitList = s: builtins.filter (x: x != "") (map lib.trim (lib.splitString "," (toString s)));

      # The store hashes a resource's kix.run/depends-on names, with the
      # `requires:` and `extra:` prefixes removed. Check 21 follows every
      # entry, whatever its prefix.
      depHashesByHash = lib.mapAttrs (
        _: e:
        map (d: lib.removePrefix "extra:" (lib.removePrefix "requires:" d)) (
          splitList ((e.r.metadata.annotations or { }).${kixKeys.dependsOn} or "")
        )
      ) byHash;

      # Every hash reachable through depends-on from the entry, as a set.
      # Empty for an entry with no hash.
      dependencyClosure =
        e:
        if e.hash == null then
          { }
        else
          builtins.listToAttrs (
            map
              (item: {
                name = item.key;
                value = true;
              })
              (
                builtins.genericClosure {
                  startSet = map (h: { key = h; }) depHashesByHash.${e.hash};
                  operator = item: map (h: { key = h; }) (depHashesByHash.${item.key} or [ ]);
                }
              )
          );

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
      # PackageInstance carrying kix.run/import-kind and kix.run/import-name
      # (scope.mkServiceRef, scope.mkSecretRef, mkImportMarker). The deploy
      # engine gates on the described object, so a reference to it resolves.
      importMarkers = builtins.concatMap (
        r:
        let
          anns = r.metadata.annotations or { };
          kind = anns.${kixKeys.importKind} or null;
          iname = anns.${kixKeys.importName} or null;
        in
        if r.kind == "PackageInstance" && kind != null && iname != null then
          [
            {
              inherit kind iname anns;
              ns = r.metadata.namespace or "cluster-scoped";
            }
          ]
        else
          [ ]
      ) resources;

      # "<kind>/<namespace>/<name>" -> the marker's annotations.
      importIds = builtins.listToAttrs (
        map (m: {
          name = "${m.kind}/${m.ns}/${m.iname}";
          value = m.anns;
        }) importMarkers
      );

      # A marker for a cluster-scoped kind (a StorageClass a flavour
      # imports into kube-system) stands for one object in the whole
      # cluster, so it resolves from every namespace: "<kind>/<name>".
      clusterImportIds = builtins.listToAttrs (
        map (m: {
          name = "${m.kind}/${m.iname}";
          value = true;
        }) (builtins.filter (m: isClusterScopedKind m.kind) importMarkers)
      );

      # Kinds that resolve through the cluster-scoped bucket: the built-in
      # cluster-scoped kinds, nothing else. Before this every kind fell back
      # to that bucket, so a Deployment in `a` could mount a ConfigMap that
      # existed only as a cluster-scoped object of the same name (kixpkgs#71
      # item 5). No check here looks up a custom cluster-scoped kind: an HPA
      # can only target namespaced kinds, and the one legitimate cluster-
      # scoped reference is a RoleBinding to a ClusterRole. A check that
      # needs another kind extends this list.
      builtInClusterScopedKinds = [
        "APIService"
        "CertificateSigningRequest"
        "ClusterRole"
        "ClusterRoleBinding"
        "CSIDriver"
        "CSINode"
        "CustomResourceDefinition"
        "IngressClass"
        "MutatingWebhookConfiguration"
        "Namespace"
        "Node"
        "PersistentVolume"
        "PriorityClass"
        "RuntimeClass"
        "StorageClass"
        "ValidatingAdmissionPolicy"
        "ValidatingAdmissionPolicyBinding"
        "ValidatingWebhookConfiguration"
        "VolumeAttachment"
      ];
      isClusterScopedKind = kind: builtins.elem kind builtInClusterScopedKinds;

      # Does `name` of `kind` exist for a referrer in namespace `ns`? The
      # namespaced bucket first; the cluster-scoped bucket and import
      # markers in any namespace only for a kind that is cluster-scoped (a
      # RoleBinding may name a ClusterRole). A name the author wrapped in
      # `kix.untrackedRef` is external by declaration and resolves whatever
      # its kind.
      hasResource =
        kind: ns: name:
        byId ? "${kind}/${ns}/${name}"
        || (isClusterScopedKind kind && byId ? "${kind}/cluster-scoped/${name}")
        || importIds ? "${kind}/${ns}/${name}"
        || (isClusterScopedKind kind && clusterImportIds ? "${kind}/${name}")
        || externalNames ? "${ns}/${name}"
        || externalNames ? "cluster-scoped/${name}";

      # Pod selectors declared by ServiceRef markers (kix.run/service-selector):
      # the operator's pods exist by declaration, so a Service or
      # NetworkPolicy in the same namespace whose selector is within one
      # of them selects real pods. A witness for checks 4 and 12, which
      # otherwise only see pod templates in the build.
      refPodSelectors = builtins.concatMap (
        r:
        let
          anns = r.metadata.annotations or { };
        in
        if r.kind == "PackageInstance" && anns ? ${kixKeys.serviceSelector} then
          [
            {
              ns = r.metadata.namespace or "cluster-scoped";
              labels = builtins.fromJSON anns.${kixKeys.serviceSelector};
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
      nsOf = r: r.metadata.namespace or "cluster-scoped";

      # A label selector reaches pods in its own namespace only, so a
      # Service, NetworkPolicy or PodDisruptionBudget in `a` is not
      # satisfied by a matching pod template in `b`. Same rule as the
      # ServiceRef witness below.
      selectsPodsIn =
        ns: selector:
        builtins.any (w: nsOf w == ns && selectorMatchesLabels selector (getPodLabels w)) workloads;

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

      # A Service (or PodDisruptionBudget) kix renders over pods an operator
      # creates at runtime has no pod template to match. The package says so
      # on the resource:
      #   metadata.annotations.<operand-of> = "<group>/<Kind>/<name>"
      # names the CR whose operand pods it selects, and checks 4 and 14
      # accept it when that CR is in the build in the same namespace. Keyed by group
      # and kind: kind names alone are not unique across API groups. This
      # replaced a global list of operator kinds plus a name-prefix guess
      # (v2_discussions/135, kixpkgs#70). Where the operator creates the
      # Service itself, scope.mkServiceRef is the better tool: nothing to
      # exempt.
      operandOfAnnotation = kixKeys.operandOf;
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
        # Headless and external-name Services have no selector.
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
          [
            "${w.kind} ${ns}/${w.metadata.name} references ServiceAccount '${saName}' which is not in the cluster build. Add the resource, or declare it as externally managed with an import or kix.untrackedRef"
          ]
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
                "${binding.kind} ${ns}/${binding.metadata.name} references ${refKind} '${refName}' which is not in the cluster build. Add the resource, or declare it as externally managed with an import or kix.untrackedRef"
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

      # Secrets are not checked because they are commonly managed
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
              "${w.kind} ${ns}/${w.metadata.name} mounts ConfigMap '${cmName}' which is not in the cluster build. Add the resource, or declare it as externally managed with an import or kix.untrackedRef"
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
            matchesAny = selectsPodsIn ns selector || selectsRefPods ns selector;
          in
          if matchesAny then
            [ ]
          else if operandOf svc != null && builtins.length (lib.splitString "/" (operandOf svc)) != 3 then
            [
              "Service ${ns}/${svc.metadata.name} declares ${operandOfAnnotation}=${operandOf svc}, which is not of the form <group>/<Kind>/<name>"
            ]
          else if operandOf svc != null then
            [
              "Service ${ns}/${svc.metadata.name} declares ${operandOfAnnotation}=${operandOf svc} but that custom resource is not in the build in namespace ${ns}. Check the annotation and include the referenced resource"
            ]
          else
            [
              "Service ${ns}/${svc.metadata.name} selector ${builtins.toJSON selector} matches no workload pod template in namespace ${ns}. Check the selector against the intended workload's pod labels"
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
            "HorizontalPodAutoscaler ${ns}/${hpa.metadata.name} targets ${refKind} '${refName}' which is not in the cluster build. Add the resource, or declare it as externally managed with an import or kix.untrackedRef"
          ]
      ) (builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources);

      # Validate StatefulSet serviceName against a headless Service.
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
                "${w.kind} ${ns}/${w.metadata.name} selector ${builtins.toJSON selectorLabels} does not match pod template labels ${builtins.toJSON templateLabels}"
              ]
          )
          (
            builtins.filter (
              r:
              builtins.elem r.kind [
                "Deployment"
                "StatefulSet"
                "DaemonSet"
                "Job"
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
            [
              "Ingress ${ns}/${ing.metadata.name} references Service '${svcName}' which is not in the cluster build. Add the resource, or declare it as externally managed with an import or kix.untrackedRef"
            ]
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
        # An empty selector matches all pods in the namespace.
        if selector == { } then
          [ ]
        else if selectsPodsIn ns selector || selectsRefPods ns selector then
          [ ]
        else
          [
            "NetworkPolicy ${ns}/${np.metadata.name} podSelector ${builtins.toJSON selector} matches no workload pod template in namespace ${ns}. Check the selector against the intended workload's pod labels"
          ]
      ) (builtins.filter (r: r.kind == "NetworkPolicy") resources);

      # Validate named Service targetPorts against container port names.
      # When a Service uses a named targetPort, that port name must exist in
      # at least one matched workload's container ports. A Service that
      # matches no pod template in the build is skipped here on purpose:
      # either check 4 already reports it, or it is exempt there because
      # its pods are an operator's (a ref witness or `kix.run/operand-of`),
      # and then there is no container spec in the build to read port
      # names from. Nothing more can be checked without the pods.

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
          matchedWorkloads = builtins.filter (
            w: nsOf w == ns && selectorMatchesLabels selector (getPodLabels w)
          ) workloads;
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

      # Validate PodDisruptionBudget selectors against pod templates.
      # A PDB whose selector matches no pod in the build protects nothing,
      # and it is also the one thing helm-dag.findOrphans used to compute
      # (for chart-internal resources only) that no other check covered.
      # Same witnesses as check 4: pod templates, ServiceRef selectors,
      # and a `kix.run/operand-of` declaration for operator-created pods.

      pdbFailures = builtins.concatMap (
        pdb:
        let
          selector = pdb.spec.selector.matchLabels or { };
          ns = pdb.metadata.namespace or "cluster-scoped";
          matchesAny = selectsPodsIn ns selector || selectsRefPods ns selector;
          decl = operandOf pdb;
        in
        # No matchLabels: an empty selector or matchExpressions only. Nothing
        # to resolve here.
        if selector == { } || matchesAny || operandCrPresent pdb then
          [ ]
        else if decl != null && builtins.length (lib.splitString "/" decl) != 3 then
          [
            "PodDisruptionBudget ${ns}/${pdb.metadata.name} declares ${operandOfAnnotation}=${decl}, which is not of the form <group>/<Kind>/<name>"
          ]
        else if decl != null then
          [
            "PodDisruptionBudget ${ns}/${pdb.metadata.name} declares ${operandOfAnnotation}=${decl} but that custom resource is not in the build in namespace ${ns}. Check the annotation and include the referenced resource"
          ]
        else
          [
            "PodDisruptionBudget ${ns}/${pdb.metadata.name} selector ${builtins.toJSON selector} matches no workload pod template in namespace ${ns}. Check the selector against the intended workload's pod labels"
          ]
      ) (builtins.filter (r: r.kind == "PodDisruptionBudget") resources);

      # --- 15. Job pods are not Service endpoints ---
      # A Job's pod is not a server. When its template labels satisfy a
      # Service selector in the same namespace, the Service routes real
      # traffic to the Job pod for as long as it runs (a probe Job built on
      # the package's selector labels did exactly this, kixpkgs#77).

      jobEndpointFailures = builtins.concatMap (
        job:
        let
          ns = job.metadata.namespace or "cluster-scoped";
          podLabels = job.spec.template.metadata.labels or { };
          selecting = builtins.filter (
            svc:
            (svc.metadata.namespace or "cluster-scoped") == ns
            && (svc.spec.selector or { }) != { }
            && selectorMatchesLabels (svc.spec.selector or { }) podLabels
          ) (builtins.filter (r: r.kind == "Service") resources);
        in
        map (
          svc:
          "Job ${ns}/${job.metadata.name} pod labels ${builtins.toJSON podLabels} satisfy Service ${ns}/${svc.metadata.name} selector ${builtins.toJSON svc.spec.selector}; the Service would route traffic to the Job pod"
        ) selecting
      ) (builtins.filter (r: r.kind == "Job") resources);

      # --- 16. kix.run/rerun is for Jobs ---
      # The deploy engine deletes and recreates a resource carrying the
      # annotation (core/annotations.nix). For a Job that is a retry; for
      # anything with a rollout it would be an outage, so the engine
      # ignores it on other kinds and the eval refuses it.

      rerunFailures = builtins.concatMap (
        r:
        let
          ns = r.metadata.namespace or "cluster-scoped";
          value = (r.metadata.annotations or { }).${kixKeys.rerun} or null;
        in
        if value == null then
          [ ]
        else if r.kind != "Job" then
          [
            "${r.kind} ${ns}/${r.metadata.name} carries ${kixKeys.rerun}=${toString value}; the rerun rule applies to Jobs only"
          ]
        else if value != kixAnnotations.values.rerunOnChange then
          [
            "Job ${ns}/${r.metadata.name} carries ${kixKeys.rerun}=${toString value}; the supported value is \"${kixAnnotations.values.rerunOnChange}\""
          ]
        else
          [ ]
      ) resources;

      # --- 17. priorityClassName references ---
      # The apiserver rejects every pod of a workload naming a PriorityClass
      # that does not exist ("no PriorityClass with name X was found"), at
      # admission, so the workload applies and then never schedules.
      # PriorityClass is cluster-scoped, so `hasResource` finds one built
      # anywhere in the cluster; the `system-` classes ship with Kubernetes
      # itself.

      builtInPriorityClasses = [
        "system-cluster-critical"
        "system-node-critical"
      ];

      priorityClassFailures = builtins.concatMap (
        w:
        let
          podSpec = getPodSpec w;
          pcName = podSpec.priorityClassName or null;
          ns = w.metadata.namespace or "cluster-scoped";
        in
        if pcName == null || builtins.elem pcName builtInPriorityClasses then
          [ ]
        else if hasResource "PriorityClass" ns pcName then
          [ ]
        else
          [
            "${w.kind} ${ns}/${w.metadata.name} sets priorityClassName '${pcName}', which no resource in this cluster creates. Every pod of this workload would be rejected at admission. Add the PriorityClass, or declare it as externally managed with an import or kix.untrackedRef"
          ]
      ) workloads;

      # --- 18. Namespaced kinds carry a namespace ---
      # The apiserver stores a namespaced object that names no namespace in
      # the requester's namespace, and the CLI keys the manifest as
      # cluster-scoped, so `kix diff` and `kix deploy --prune` would treat
      # the live object as an orphan of the build that created it. Kix knows
      # the scope of the built-in kinds below, of every custom kind whose
      # CustomResourceDefinition is in this build (`spec.scope`), and of every
      # kind a CRD ref marker declares (`kix.run/crd-scope`); any other custom
      # kind is left to the deploy-time check in the CLI.

      builtInNamespacedKinds = {
        "" = [
          "ConfigMap"
          "Endpoints"
          "Event"
          "LimitRange"
          "PersistentVolumeClaim"
          "Pod"
          "PodTemplate"
          "ReplicationController"
          "ResourceQuota"
          "Secret"
          "Service"
          "ServiceAccount"
        ];
        "apps" = [
          "ControllerRevision"
          "DaemonSet"
          "Deployment"
          "ReplicaSet"
          "StatefulSet"
        ];
        "autoscaling" = [ "HorizontalPodAutoscaler" ];
        "batch" = [
          "CronJob"
          "Job"
        ];
        "coordination.k8s.io" = [ "Lease" ];
        "discovery.k8s.io" = [ "EndpointSlice" ];
        "events.k8s.io" = [ "Event" ];
        "networking.k8s.io" = [
          "Ingress"
          "NetworkPolicy"
        ];
        "policy" = [ "PodDisruptionBudget" ];
        "rbac.authorization.k8s.io" = [
          "Role"
          "RoleBinding"
        ];
        "storage.k8s.io" = [ "CSIStorageCapacity" ];
      };

      namespacedCustomKinds =
        builtins.listToAttrs (
          map
            (crd: {
              name = "${crd.spec.group}/${crd.spec.names.kind}";
              value = true;
            })
            (
              builtins.filter (
                r: r.kind == "CustomResourceDefinition" && (r.spec.scope or "") == "Namespaced"
              ) resources
            )
        )
        // builtins.listToAttrs (
          map (d: {
            name = "${d.group}/${d.kind}";
            value = true;
          }) (builtins.filter (d: d.scope == "Namespaced") crdRefDecls)
        );

      isNamespacedKind =
        r:
        let
          group = groupOf (r.apiVersion or "");
        in
        builtins.elem r.kind (builtInNamespacedKinds.${group} or [ ])
        || namespacedCustomKinds ? "${group}/${r.kind}";

      missingNamespaceFailures = map (
        r:
        "${r.kind} ${r.metadata.name or "unnamed"} (${r.apiVersion or ""}) is a namespaced kind but has no metadata.namespace. Create it with a namespaced scope (scope.mkResource) rather than scope.mkClusterResource, or set metadata.namespace"
      ) (builtins.filter (r: !(r.metadata ? namespace) && isNamespacedKind r) resources);

      # --- 19. PersistentVolumeClaim references ---
      # A pod that mounts a claim that does not exist stays Pending.

      safeList = v: if builtins.isList v then v else [ ];
      # A chart may render `data: null`; Nix's `or` handles missing
      # attributes only.
      attrNamesOf = v: if builtins.isAttrs v then builtins.attrNames v else [ ];

      claimFailures = builtins.concatMap (
        w:
        let
          ns = nsOf w;
        in
        builtins.concatMap (
          vol:
          let
            claim = vol.persistentVolumeClaim.claimName or null;
          in
          if claim == null || hasResource "PersistentVolumeClaim" ns claim then
            [ ]
          else
            [
              "${w.kind} ${ns}/${w.metadata.name} mounts PersistentVolumeClaim '${claim}', which is not in the cluster build, so its pods would stay Pending. Take the claim as a dependency (a persistent-volume-claim instance) and mount its out.name, or declare a claim something else creates with an import or kix.untrackedRef (with by = <creator> when a resource in the build creates it)."
            ]
        ) (safeList ((getPodSpec w).volumes or [ ]))
      ) workloads;

      # --- 20. StorageClass references ---
      # A claim that names a StorageClass nobody creates stays Pending. Read
      # from PersistentVolumeClaims, StatefulSet volumeClaimTemplates, and
      # generic ephemeral volumes. Classes in operator custom resources (an
      # SGCluster's, a VMCluster's) are not read here.

      persistentVolumeClasses = builtins.listToAttrs (
        builtins.concatMap (
          r:
          let
            sc = r.spec.storageClassName or null;
          in
          if r.kind == "PersistentVolume" && sc != null then
            [
              {
                name = sc;
                value = true;
              }
            ]
          else
            [ ]
        ) resources
      );

      storageClassFailure =
        who: ns: sc:
        if
          sc == null || sc == "" || hasResource "StorageClass" ns sc || persistentVolumeClasses ? ${sc}
        then
          [ ]
        else
          [
            "${who} requests StorageClass '${sc}', which nothing in this cluster creates or imports, so the claim would stay Pending. Take the class from a storageClasses provider, add the StorageClass, declare one the environment provides with kix.mkImport { kind = \"StorageClass\"; apiVersion = \"storage.k8s.io/v1\"; out.name = \"${sc}\"; } (not optional, or resolved by a dependency), or wrap the name in kix.untrackedRef."
          ];

      storageClassFailures =
        builtins.concatMap (
          pvc: storageClassFailure (describe pvc) (nsOf pvc) (pvc.spec.storageClassName or null)
        ) (builtins.filter (r: r.kind == "PersistentVolumeClaim") resources)
        ++ builtins.concatMap (
          sts:
          builtins.concatMap (
            t:
            storageClassFailure
              "StatefulSet ${nsOf sts}/${sts.metadata.name} volumeClaimTemplate '${t.metadata.name or "unnamed"}'"
              (nsOf sts)
              (t.spec.storageClassName or null)
          ) (safeList (sts.spec.volumeClaimTemplates or [ ]))
        ) (builtins.filter (r: r.kind == "StatefulSet") resources)
        ++ builtins.concatMap (
          w:
          builtins.concatMap (
            vol:
            let
              t = vol.ephemeral.volumeClaimTemplate or null;
            in
            if t == null then
              [ ]
            else
              storageClassFailure
                "${w.kind} ${nsOf w}/${w.metadata.name} ephemeral volume '${vol.name or "unnamed"}'"
                (nsOf w)
                (t.spec.storageClassName or null)
          ) (safeList ((getPodSpec w).volumes or [ ]))
        ) workloads;

      # --- 21. Custom resources depend on a declaration of their kind ---
      # The apiserver rejects an object whose kind it does not serve, and
      # the deploy orders a custom resource after its CRD only through a
      # kix.run/depends-on path. So every object outside the built-in API
      # groups must reach, through depends-on, a declaration of its group
      # and kind that serves its version: a CustomResourceDefinition, a CRD
      # ref marker (scope.mkCRDRef, kix.mkImport crds), or an APIService for
      # the group (resource or import marker).

      builtInGroups = [
        ""
        "apps"
        "batch"
        "autoscaling"
        "policy"
        "networking.k8s.io"
        "rbac.authorization.k8s.io"
        "storage.k8s.io"
        "scheduling.k8s.io"
        "admissionregistration.k8s.io"
        "apiextensions.k8s.io"
        "apiregistration.k8s.io"
        "coordination.k8s.io"
        "discovery.k8s.io"
        "events.k8s.io"
        "node.k8s.io"
        "certificates.k8s.io"
        "flowcontrol.apiserver.k8s.io"
        "resource.k8s.io"
        "authentication.k8s.io"
        "authorization.k8s.io"
        "internal.apiserver.k8s.io"
        "storagemigration.k8s.io"
        kixAnnotations.group
      ];

      versionOf =
        apiVersion:
        let
          parts = lib.splitString "/" apiVersion;
        in
        lib.last parts;

      # Declarations: { group; kind (null: any kind of the group); served;
      # scope; text; e }.
      crdDecls = builtins.concatMap (
        e:
        if e.r.kind == "CustomResourceDefinition" then
          [
            {
              group = e.r.spec.group or "";
              kind = e.r.spec.names.kind or "";
              served = map (v: v.name) (
                builtins.filter (v: v.served or true) (safeList (e.r.spec.versions or [ ]))
              );
              scope = e.r.spec.scope or "Namespaced";
              text = "CustomResourceDefinition ${e.r.metadata.name or "unnamed"}";
              inherit e;
            }
          ]
        else
          [ ]
      ) entries;

      crdRefDecls = builtins.concatMap (
        e:
        let
          anns = e.r.metadata.annotations or { };
          crdName = anns.${kixKeys.importName} or "";
          dot = lib.splitString "." crdName;
        in
        if e.r.kind == "PackageInstance" && anns ? ${kixKeys.crdKind} then
          [
            {
              group = builtins.concatStringsSep "." (builtins.tail dot);
              kind = anns.${kixKeys.crdKind};
              served =
                if anns ? ${kixKeys.crdServedVersions} then
                  splitList anns.${kixKeys.crdServedVersions}
                else
                  [ (anns.${kixKeys.crdVersion} or "") ];
              scope = anns.${kixKeys.crdScope} or "Namespaced";
              text = "the CRD ref ${e.r.metadata.name} for ${crdName}";
              inherit e;
            }
          ]
        else
          [ ]
      ) entries;

      apiServiceDecls = builtins.concatMap (
        e:
        let
          anns = e.r.metadata.annotations or { };
          fromName =
            name:
            let
              parts = lib.splitString "." name;
            in
            {
              version = builtins.head parts;
              group = builtins.concatStringsSep "." (builtins.tail parts);
            };
          decl = gv: text: {
            inherit (gv) group;
            kind = null;
            served = [ gv.version ];
            scope = null;
            inherit text e;
          };
        in
        if e.r.kind == "APIService" then
          [
            (decl {
              group = e.r.spec.group or "";
              version = e.r.spec.version or "";
            } "APIService ${e.r.metadata.name or "unnamed"}")
          ]
        else if e.r.kind == "PackageInstance" && (anns.${kixKeys.importKind} or null) == "APIService" then
          [
            (decl (fromName
              anns.${kixKeys.importName}
            ) "the import of APIService ${anns.${kixKeys.importName}} (${e.r.metadata.name})")
          ]
        else
          [ ]
      ) entries;

      kindDecls = crdDecls ++ crdRefDecls ++ apiServiceDecls;

      customResourceFailures = builtins.concatMap (
        e:
        let
          r = e.r;
          apiVersion = r.apiVersion or "";
          group = groupOf apiVersion;
          version = versionOf apiVersion;
          matching = builtins.filter (d: d.group == group && (d.kind == null || d.kind == r.kind)) kindDecls;
          closure = dependencyClosure e;
          reachable = builtins.filter (d: d.e.hash != null && closure ? ${d.e.hash}) matching;
          provider = d: if d.e.owner == null then "" else " (instance ${d.e.owner})";
          chartSentence = "If a Helm chart renders it (a values toggle), turn the toggle off and build it with the owner's builder in a package of your own; a chart resource cannot take the dependency.";
        in
        if builtins.elem group builtInGroups then
          [ ]
        else if matching == [ ] then
          [
            "${describe r} (${apiVersion}${
              lib.optionalString (e.owner != null) ", instance ${e.owner}"
            }) has no CustomResourceDefinition in the cluster build, so the apiserver would reject it at apply. Take the package that installs the CRD as a dependency and build the resource with its builder (scope.mkCR dep.out.crds.<Kind>, or dep.out.mk<Kind> where it exists), vendor the CRD as JSON and build it with scope.mkCRD (scripts/vendor-crds.py fetches upstream CRDs), or declare a CRD installed outside Kix with scope.mkCRDRef { group = \"${group}\"; kind = \"${r.kind}\"; version = \"${version}\"; ... } and build with scope.mkCR. ${chartSentence}"
          ]
        else if reachable == [ ] then
          let
            own = builtins.filter (d: e.owner != null && d.e.owner == e.owner) matching;
            d = builtins.head matching;
          in
          if own != [ ] then
            [
              "${describe r}${instanceClause e.owner} does not depend on ${(builtins.head own).text}, which the same instance declares, so the deploy can apply it before the CRD is served. Build it with scope.mkCR from that declaration, or list the declaration in its requires."
            ]
          else
            [
              "${describe r}${instanceClause e.owner} does not depend on ${d.text}${provider d}, which declares its kind, so the deploy can apply it before the CRD is served. Take ${
                if d.e.owner == null then "that instance" else d.e.owner
              } as a dependency${
                lib.optionalString (e.owner != null) " of ${e.owner}"
              } and build the resource with its builder, which adds the dependency. ${chartSentence}"
            ]
        else if builtins.any (d: builtins.elem version d.served) reachable then
          [ ]
        else
          let
            d = builtins.head reachable;
          in
          [
            "${describe r} uses ${apiVersion}, but ${d.text}${provider d} serves ${builtins.concatStringsSep ", " d.served} for ${group}/${r.kind}. Use a served version, or correct the declaration."
          ]
      ) entries;

      # --- 22. Named Secret and ConfigMap keys ---
      # A container does not start when an env var or volume item names a
      # key its Secret or ConfigMap lacks, and a subPath of a missing key
      # mounts an empty directory. Keys are known for a Secret built with
      # scope.mkSecret (kix.run/secret-keys), a ref that lists keys
      # (kix.run/import-secret-keys) and a ConfigMap in the build (data,
      # binaryData). Skipped: `optional: true`; names declared external with
      # kix.untrackedRef (a controller-created Secret); names with no object
      # in the build, which check 3 and the deploy own; Secrets without
      # kix.run/secret-keys (a chart's); objects that cede their data fields
      # to another manager. Whole use (envFrom, a volume without items) reads
      # no named key and is not checked.

      cedesData =
        r:
        builtins.any (
          p: lib.hasPrefix "data" p || lib.hasPrefix "binaryData" p || lib.hasPrefix "stringData" p
        ) (splitList ((r.metadata.annotations or { }).${kixKeys.cedeFields} or ""));

      # { keys = [ ... ]; } when the keys are known, { opaque = true; } for
      # a Secret ref that lists none, null when nothing is checked.
      declaredKeys =
        objKind: ns: name:
        let
          id = "${objKind}/${ns}/${name}";
          r = byId.${id};
          anns = r.metadata.annotations or { };
          refAnns = importIds.${id};
        in
        if externalNames ? "${ns}/${name}" then
          null
        else if byId ? ${id} then
          if cedesData r then
            null
          else if objKind == "Secret" then
            if anns ? ${kixKeys.secretKeys} then { keys = splitList anns.${kixKeys.secretKeys}; } else null
          else
            {
              keys = attrNamesOf (r.data or null) ++ attrNamesOf (r.binaryData or null);
            }
        else if objKind == "Secret" && importIds ? ${id} then
          if refAnns ? ${kixKeys.importSecretKeys} then
            { keys = splitList refAnns.${kixKeys.importSecretKeys}; }
          else
            { opaque = true; }
        else
          null;

      keyReadsOf =
        w:
        let
          ps = getPodSpec w;
          containers = safeList (ps.containers or [ ]) ++ safeList (ps.initContainers or [ ]);
          volumes = safeList (ps.volumes or [ ]);
          volumesByName = builtins.listToAttrs (
            map (v: {
              name = v.name or "";
              value = v;
            }) volumes
          );
          itemReads =
            objKind: obj: items: where:
            map (it: {
              inherit objKind obj where;
              key = it.key;
              subPath = null;
            }) (builtins.filter (it: it ? key) (safeList items));

          envReads = builtins.concatMap (
            c:
            builtins.concatMap (
              ev:
              let
                read =
                  objKind: ref:
                  if ref == null || (ref.optional or false) || !(ref ? name) || !(ref ? key) then
                    [ ]
                  else
                    [
                      {
                        inherit objKind;
                        obj = ref.name;
                        key = ref.key;
                        where = "env ${ev.name or "?"} of container ${c.name or "?"}";
                        subPath = null;
                      }
                    ];
              in
              read "Secret" (ev.valueFrom.secretKeyRef or null)
              ++ read "ConfigMap" (ev.valueFrom.configMapKeyRef or null)
            ) (safeList (c.env or [ ]))
          ) containers;

          volumeReads = builtins.concatMap (
            v:
            let
              where = "volume ${v.name or "?"} items";
              sec = v.secret or null;
              cm = v.configMap or null;
              sources = safeList ((v.projected or { }).sources or [ ]);
            in
            (
              if sec != null && !(sec.optional or false) && sec ? secretName then
                itemReads "Secret" sec.secretName (sec.items or [ ]) where
              else
                [ ]
            )
            ++ (
              if cm != null && !(cm.optional or false) && cm ? name then
                itemReads "ConfigMap" cm.name (cm.items or [ ]) where
              else
                [ ]
            )
            ++ builtins.concatMap (
              s:
              let
                ps' = s.secret or null;
                pc = s.configMap or null;
              in
              (
                if ps' != null && !(ps'.optional or false) && ps' ? name then
                  itemReads "Secret" ps'.name (ps'.items or [ ]) where
                else
                  [ ]
              )
              ++ (
                if pc != null && !(pc.optional or false) && pc ? name then
                  itemReads "ConfigMap" pc.name (pc.items or [ ]) where
                else
                  [ ]
              )
            ) sources
          ) volumes;

          # A subPath into a Secret or ConfigMap volume without `items`
          # names a key by its first path segment.
          subPathReads = builtins.concatMap (
            c:
            builtins.concatMap (
              m:
              let
                v = volumesByName.${m.name or ""} or { };
                sub = m.subPath or "";
                key = builtins.head (lib.splitString "/" sub);
                read = objKind: obj: {
                  inherit objKind obj key;
                  where = "container ${c.name or "?"}";
                  subPath = {
                    inherit sub;
                    mountPath = m.mountPath or "?";
                  };
                };
                noItems = src: safeList (src.items or [ ]) == [ ];
              in
              if sub == "" then
                [ ]
              else if
                v ? secret && !(v.secret.optional or false) && v.secret ? secretName && noItems v.secret
              then
                [ (read "Secret" v.secret.secretName) ]
              else if
                v ? configMap && !(v.configMap.optional or false) && v.configMap ? name && noItems v.configMap
              then
                [ (read "ConfigMap" v.configMap.name) ]
              else
                [ ]
            ) (safeList (c.volumeMounts or [ ]))
          ) containers;
        in
        envReads ++ volumeReads ++ subPathReads;

      keyFailures = builtins.concatMap (
        w:
        let
          ns = nsOf w;
          who = "${w.kind} ${ns}/${w.metadata.name}";
        in
        builtins.concatMap (
          read:
          let
            decl = declaredKeys read.objKind ns read.obj;
            listText = keys: if keys == [ ] then "no keys" else "keys ${builtins.concatStringsSep ", " keys}";
          in
          if decl == null then
            [ ]
          else if decl ? opaque then
            [
              "${who} reads key '${read.key}' of Secret '${read.obj}' (${read.where}), whose scope.mkSecretRef declares no keys, so the deploy cannot check the Secret holds it. List the keys the pod reads in keys."
            ]
          else if builtins.elem read.key decl.keys then
            [ ]
          else if read.subPath != null then
            [
              "${who} mounts subPath '${read.subPath.sub}' of ${read.objKind} '${read.obj}' at ${read.subPath.mountPath} (${read.where}), and ${read.objKind} '${read.obj}' declares ${listText decl.keys}, not '${read.key}'. The kubelet would mount an empty directory there, so the container fails to start or reads a directory instead of the file. Add the key to the ${read.objKind}, or mount a declared one."
            ]
          else
            [
              "${who} reads key '${read.key}' of ${read.objKind} '${read.obj}' (${read.where}), which declares ${listText decl.keys}. The container would not start. Add the key to the ${read.objKind}, or read a declared one."
            ]
        ) (lib.unique (keyReadsOf w))
      ) workloads;

      # --- 23. One default per cluster ---
      # The apiserver accepts one PriorityClass with globalDefault. For
      # StorageClass and IngressClass, admission gives an object that names
      # no class the newest default, so two defaults in one build make the
      # result depend on apply order.

      defaultFailures =
        let
          owned = e: "${e.r.metadata.name or "unnamed"}${instanceClause e.owner}";
          # Kubernetes still treats a StorageClass with the beta annotation
          # as a default (IsDefaultAnnotation in pkg/apis/storage/util).
          annotated =
            keys: e: builtins.any (key: ((e.r.metadata.annotations or { }).${key} or null) == "true") keys;
          check =
            kind: isDefault: text:
            let
              defaults = builtins.filter (e: e.r.kind == kind && isDefault e) entries;
            in
            if builtins.length defaults < 2 then
              [ ]
            else
              [ (text (builtins.concatStringsSep ", " (map owned defaults))) ];
        in
        check "PriorityClass" (e: (e.r.globalDefault or false) == true) (
          names:
          "PriorityClasses ${names} all set globalDefault: true. The apiserver accepts one; set it on one class."
        )
        ++
          check "StorageClass"
            (annotated [
              "storageclass.kubernetes.io/is-default-class"
              "storageclass.beta.kubernetes.io/is-default-class"
            ])
            (
              names:
              "StorageClasses ${names} are all annotated as the default. Kubernetes gives a claim with no class the newest one, which here depends on apply order; annotate one."
            )
        ++ check "IngressClass" (annotated [ "ingressclass.kubernetes.io/is-default-class" ]) (
          names:
          "IngressClasses ${names} are all annotated as the default. Kubernetes gives an Ingress with no class the newest one, which here depends on apply order; annotate one."
        );

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
        ++ portNameFailures
        ++ pdbFailures
        ++ jobEndpointFailures
        ++ rerunFailures
        ++ priorityClassFailures
        ++ missingNamespaceFailures
        ++ claimFailures
        ++ storageClassFailures
        ++ customResourceFailures
        ++ keyFailures
        ++ defaultFailures;
    in
    allFailures;
}
