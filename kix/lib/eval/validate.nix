# Validate cross-resource references and selectors across a cluster's rendered
# manifests.
#
# `crossResourceFailures { manifests, identityHashes, owners, externalNames }`
# returns a list of failure messages. `identityHashes` and `owners` align with
# `manifests` and record the store hash used in `kix.run/depends-on` and the
# `<namespace>/<instance>` owner of each resource. `externalNames` contains
# `<namespace>/<name>` entries marked with `kix.untrackedRef` before string
# context is stripped. Import markers (`PackageInstance` resources with
# `kix.run/import-kind` and `kix.run/import-name`) satisfy reference and
# selector lookups for the external resources they represent.
#
# These checks verify that referenced resources and pod labels exist in the
# rendered manifest set after string context is stripped. Provenance checks
# that inspect string context live in `kix/lib/rules/`.

{ lib }:

let
  kixAnnotations = import ../core/annotations.nix;
  helpers = import ./helpers.nix { inherit lib; };
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

      describe =
        r:
        let
          ns = r.metadata.namespace or null;
          name = r.metadata.name or "unnamed";
        in
        if ns == null then "${r.kind} ${name}" else "${r.kind} ${ns}/${name}";

      instanceClause = owner: if owner == null then "" else " (instance ${owner})";

      splitList = s: builtins.filter (x: x != "") (map lib.trim (lib.splitString "," (toString s)));

      # Map each resource hash to the dependency hashes in `kix.run/depends-on`,
      # stripping `requires:` and `extra:` prefixes.
      depHashesByHash = lib.mapAttrs (
        _: e:
        map (d: lib.removePrefix "extra:" (lib.removePrefix "requires:" d)) (
          splitList ((e.r.metadata.annotations or { }).${kixKeys.dependsOn} or "")
        )
      ) byHash;

      # Return the set of resource hashes transitively reachable through
      # `kix.run/depends-on`.
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

      resourceId =
        r:
        let
          ns = r.metadata.namespace or "cluster-scoped";
          name = r.metadata.name or "unnamed";
        in
        "${r.kind}/${ns}/${name}";

      byId = builtins.foldl' (acc: r: acc // { "${resourceId r}" = r; }) { } resources;

      # Collect import markers (`PackageInstance` resources with
      # `kix.run/import-kind` and `kix.run/import-name`) that represent
      # external resources.
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

      importIds = builtins.listToAttrs (
        map (m: {
          name = "${m.kind}/${m.ns}/${m.iname}";
          value = m.anns;
        }) importMarkers
      );

      # Index cluster-scoped import markers by `<kind>/<name>` so they resolve
      # from any namespace.
      clusterImportIds = builtins.listToAttrs (
        map (m: {
          name = "${m.kind}/${m.iname}";
          value = true;
        }) (builtins.filter (m: isClusterScopedKind m.kind) importMarkers)
      );

      # Report whether `kind` is a built-in cluster-scoped kind that can
      # resolve across namespaces.
      isClusterScopedKind = kind: builtins.elem kind helpers.builtInClusterScopedKinds;

      # Check whether `kind` `name` resolves in namespace `ns`, as a
      # cluster-scoped resource, through an import marker, or via
      # `kix.untrackedRef`.
      hasResource =
        kind: ns: name:
        byId ? "${kind}/${ns}/${name}"
        || (isClusterScopedKind kind && byId ? "${kind}/cluster-scoped/${name}")
        || importIds ? "${kind}/${ns}/${name}"
        || (isClusterScopedKind kind && clusterImportIds ? "${kind}/${name}")
        || externalNames ? "${ns}/${name}"
        || externalNames ? "cluster-scoped/${name}";

      # Collect pod selectors declared on ServiceRef import markers
      # (`kix.run/service-selector`) so Services, NetworkPolicies, and PDBs can
      # match operator-managed pods.
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

      # Check whether `selector` matches any workload pod template in namespace `ns`.
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

      getPodLabels =
        r:
        if r.kind == "CronJob" then
          r.spec.jobTemplate.spec.template.metadata.labels or { }
        else
          r.spec.template.metadata.labels or { };

      selectorMatchesLabels =
        selector: labels: builtins.all (k: (labels.${k} or null) == selector.${k}) (lib.attrNames selector);

      # --- Allowlists for external references ---

      # Report whether `name` is a built-in cluster role provided by Kubernetes.
      externalRoleRef =
        name:
        lib.hasPrefix "system:" name
        || lib.hasSuffix "-psp" name
        || builtins.elem name [
          "admin"
          "cluster-admin"
          "edit"
          "view"
          # The kube-system Role that reads the extension-apiserver-authentication
          # ConfigMap, which an aggregated API server needs.
          "extension-apiserver-authentication-reader"
        ];

      # Services and PodDisruptionBudgets that select pods created at runtime
      # by an operator have no pod template in the build. They annotate
      # `kix.run/operand-of = "<group>/<Kind>/<name>"` to reference the custom
      # resource in the same namespace whose operand pods they select.
      operandOfAnnotation = kixKeys.operandOf;
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
        selector == { }
        || builtins.any (sc: selectorMatchesLabels sc selector) systemComponentSelectors
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

      # Check ConfigMap volume mounts. Secret mounts are not checked here
      # because Secrets are often provisioned by external controllers.

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

      # Report whether `ns` is a `_`-prefixed sentinel namespace for
      # cluster-level instances, which do not emit a Namespace resource.
      isSentinelNamespace = ns: lib.hasPrefix "_" ns;

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

      # Validate that named Service targetPorts exist on at least one matched
      # workload container. Services that match no workload pod template in the
      # build are skipped because check 4 either reports them or exempts them as
      # operator-managed.

      portNameFailures = builtins.concatMap (
        svc:
        let
          selector = svc.spec.selector or { };
          ns = svc.metadata.namespace or "cluster-scoped";
          svcPorts = svc.spec.ports or [ ];
          namedTargetPorts = builtins.filter (
            p:
            let
              tp = p.targetPort or null;
            in
            tp != null && builtins.isString tp
          ) svcPorts;
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

      # Validate that each PodDisruptionBudget `matchLabels` selector matches a
      # workload pod template, a ServiceRef selector, or an `operand-of` custom
      # resource.

      pdbFailures = builtins.concatMap (
        pdb:
        let
          selector = pdb.spec.selector.matchLabels or { };
          ns = pdb.metadata.namespace or "cluster-scoped";
          matchesAny = selectsPodsIn ns selector || selectsRefPods ns selector;
          decl = operandOf pdb;
        in
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
      # Reject Jobs whose pod labels match a Service selector in the same
      # namespace, which would route Service traffic to the Job pod while it
      # runs.

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
      # The deploy engine deletes and recreates resources annotated with
      # `kix.run/rerun`. Reject the annotation on non-Job resources, where
      # recreation would cause an outage.

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
      # Admission rejects pods whose `priorityClassName` does not exist, leaving
      # the workload unscheduled. PriorityClass is cluster-scoped, and
      # Kubernetes provides `system-cluster-critical` and `system-node-critical`
      # by default.

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
      # A namespaced resource without `metadata.namespace` is stored in the
      # default namespace by the API server while the CLI tracks it as
      # cluster-scoped, breaking diff and prune. Check built-in namespaced kinds
      # and custom kinds declared as `Namespaced` by a CRD or CRD ref marker in
      # the build.

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
      # Helm charts can render `data: null`, whereas Nix's `or` only handles
      # missing attributes.
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
            "${who} requests StorageClass '${sc}', which nothing in this cluster creates or imports, so the claim would stay Pending. Take the class from a storageClasses provider, add the StorageClass, declare one the environment provides with kix.mkImport { kind = \"StorageClass\"; apiVersion = \"storage.k8s.io/v1\"; out.name = \"${sc}\"; } (not optional, or demanded by a required dependency), or wrap the name in kix.untrackedRef."
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
      # Every resource outside the built-in API groups must depend (via
      # `kix.run/depends-on`) on a CustomResourceDefinition, CRD ref marker, or
      # APIService that serves its group, kind, and version.

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
              served = splitList anns.${kixKeys.crdServedVersions};
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
      # Validate that env vars, volume `items`, and `subPath` mounts reference
      # keys that exist on their target Secret or ConfigMap. Known keys come
      # from `kix.run/secret-keys` on `scope.mkSecret`,
      # `kix.run/import-secret-keys` on Secret refs, and `data` or `binaryData`
      # on ConfigMaps. Skip optional references, `kix.untrackedRef` names,
      # Secret resources without `kix.run/secret-keys`, and resources that cede
      # their data fields.

      cedesData =
        r:
        builtins.any (
          p: lib.hasPrefix "data" p || lib.hasPrefix "binaryData" p || lib.hasPrefix "stringData" p
        ) (splitList ((r.metadata.annotations or { }).${kixKeys.cedeFields} or ""));

      # Return `{ keys }` when the target's keys are known,
      # `{ noKeysListed = true }` for a Secret ref without declared keys, or
      # null when unchecked.
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
            { noKeysListed = true; }
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
          else if decl ? noKeysListed then
            [
              "${who} reads key '${read.key}' of Secret '${read.obj}' (${read.where}), whose scope.mkSecretRef declares no keys, so the deploy cannot check the Secret holds it. List the keys the pod reads in keys."
            ]
          else if builtins.elem read.key decl.keys then
            [ ]
          else if read.subPath != null then
            [
              "${who} mounts subPath '${read.subPath.sub}' of ${read.objKind} '${read.obj}' at ${read.subPath.mountPath} (${read.where}), and ${read.objKind} '${read.obj}' declares ${listText decl.keys}, not '${read.key}'. The kubelet would mount an empty directory there: the container fails to start if its image has a file at ${read.subPath.mountPath}, and otherwise reads a directory instead of the file. Add the key to the ${read.objKind}, or mount a declared one."
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
