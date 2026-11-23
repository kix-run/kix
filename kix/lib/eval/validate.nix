# Validate cross-resource references and selectors across a cluster's rendered
# manifests.
#
# `crossResourceFailures { manifests, identityHashes, owners, externalNames }`
# returns a list of failures. A failure is a message, or `{ message; fix; }`
# when the check knows what to change. `identityHashes` and `owners` align with
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
  validateCrds = import ./validate-crds.nix { inherit lib; };
  validateKeys = import ./validate-keys.nix { inherit lib; };
  kixKeys = kixAnnotations.keys;
  labelSelector = import ../core/label-selector.nix { inherit lib; };
  inherit (import ../core/util.nix { inherit lib; })
    listOr
    groupOf
    namespaceOf
    splitList
    ;
  workloadKinds = import ../core/workload-kinds.nix { inherit lib; };
  podSpecReader = import ../core/pod-spec.nix { inherit lib; };
in
rec {
  # Return a failure of `crossResourceFailures` as one text, for tests.
  failureText = f: if builtins.isString f then f else "${f.message}\nFix: ${f.fix}";

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

      # Map each resource hash to the dependency hashes in `kix.run/depends-on`,
      # stripping `requires:` and `extra:` prefixes.
      depHashesByHash = lib.mapAttrs (
        _: e:
        map (d: lib.removePrefix "extra:" (lib.removePrefix "requires:" d)) (
          splitList (e.r.metadata.annotations.${kixKeys.dependsOn} or "")
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

      # The last of several resources with one id wins, as the duplicate
      # check reports them separately.
      byId = builtins.listToAttrs (
        map (r: lib.nameValuePair (resourceId r) r) (lib.reverseList resources)
      );

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
        ns: selector: builtins.any (w: w.ns == ns && selectorMatches selector w.labels) refPodSelectors;

      workloads = builtins.filter (r: builtins.elem r.kind workloadKinds.builtKinds) resources;
      nsOf = namespaceOf;

      # Check whether `selector` matches any workload pod template in namespace `ns`.
      selectsPodsIn =
        ns: selector: builtins.any (w: nsOf w == ns && selectorMatches selector (getPodLabels w)) workloads;

      getPodSpec = podSpecReader.podSpecOf;
      getPodLabels = r: (podSpecReader.podTemplateOf r).metadata.labels or { };

      selectorMatches = labelSelector.matches;
      # Return true when the label map `selector`, such as a Service's
      # `spec.selector`, matches `labels`.
      mapMatches = selector: selectorMatches { matchLabels = selector; };

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
      crIds = builtins.listToAttrs (
        map (r: {
          name = "${groupOf (r.apiVersion or "")}/${r.kind}/${
            r.metadata.namespace or "cluster-scoped"
          }/${r.metadata.name or "unnamed"}";
          value = true;
        }) resources
      );
      operandOf = svc: svc.metadata.annotations.${operandOfAnnotation} or null;
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
        || builtins.any (sc: mapMatches sc selector) systemComponentSelectors
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
            {
              message = "${w.kind} ${ns}/${w.metadata.name} sets serviceAccountName '${saName}', which no ServiceAccount in namespace '${ns}' creates.";
              fix =
                "Check '${saName}' for a typo, or add the ServiceAccount to the package and set serviceAccount = self.<part>; on the workload."
                + "\nIf something outside Kix creates '${saName}', set serviceAccountName = kix.untrackedRef \"${saName}\"; or declare a kix.mkImport instance.";
            }
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
                {
                  message = "${binding.kind} ${ns}/${binding.metadata.name} references ${refKind} '${refName}', which no resource in this cluster creates.";
                  fix =
                    "Check '${refName}' for a typo, or add the ${refKind} to the package or cluster and reference its .out.name."
                    + "\nIf something outside Kix creates '${refName}', wrap the name in kix.untrackedRef \"${refName}\" or declare a kix.mkImport instance.";
                }
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
              {
                message = "${w.kind} ${ns}/${w.metadata.name} mounts ConfigMap '${cmName}', which no resource in namespace '${ns}' creates.";
                fix =
                  "Check '${cmName}' for a typo, or add the ConfigMap to the package and mount it with kix.mount.configMap (or reference its .out.name)."
                  + "\nIf something outside Kix creates '${cmName}', wrap the name in kix.untrackedRef \"${cmName}\" (with by = <creator> when a resource in this build creates it at runtime).";
              }
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
              selectsPodsIn ns { matchLabels = selector; } || selectsRefPods ns { matchLabels = selector; };
          in
          if matchesAny then
            [ ]
          else if operandOf svc != null && builtins.length (lib.splitString "/" (operandOf svc)) != 3 then
            [
              {
                message = "Service ${ns}/${svc.metadata.name} sets ${operandOfAnnotation}=${operandOf svc}, which is not in the form <group>/<Kind>/<name>.";
                fix = "Write the annotation as \"<group>/<Kind>/<name>\", for example \"postgresql.cnpg.io/Cluster/db\".";
              }
            ]
          else if operandOf svc != null then
            [
              {
                message = "Service ${ns}/${svc.metadata.name} sets ${operandOfAnnotation}=${operandOf svc}, which no custom resource in namespace '${ns}' creates.";
                fix = "Check the annotation for a typo, or include the custom resource in namespace '${ns}'.";
              }
            ]
          else
            [
              {
                message = "Service ${ns}/${svc.metadata.name} selector ${builtins.toJSON selector} matches no workload pod template in namespace '${ns}'.";
                fix = "Update spec.selector to match the target workload's pod labels, or build the Service with kix.service.fromWorkload.";
              }
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
            {
              message = "HorizontalPodAutoscaler ${ns}/${hpa.metadata.name} targets ${refKind} '${refName}', which no resource in namespace '${ns}' creates.";
              fix =
                "Check scaleTargetRef.name ('${refName}') for a typo, or set name = <workload>.out.name; so it points to a workload in namespace '${ns}'."
                + "\nIf something outside Kix creates '${refName}', wrap the name in kix.untrackedRef \"${refName}\" or declare a kix.mkImport instance.";
            }
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

      duplicateFailures =
        let
          counts = lib.mapAttrs (_: builtins.length) (builtins.groupBy resourceId resources);
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
      # A workload's spec.selector must match its pod template labels,
      # otherwise the workload will never match its pods.

      selectorConsistencyFailures = builtins.concatMap (
        w:
        let
          selector = w.spec.selector or { };
          templateLabels = w.spec.template.metadata.labels or { };
          ns = w.metadata.namespace or "cluster-scoped";
        in
        if labelSelector.isEmpty selector then
          [ ]
        else if selectorMatches selector templateLabels then
          [ ]
        else
          [
            "${w.kind} ${ns}/${w.metadata.name} spec.selector ${builtins.toJSON selector} does not match pod template labels ${builtins.toJSON templateLabels}, so Kubernetes would reject it. Update spec.template.metadata.labels or spec.selector so they match."
          ]
      ) (builtins.filter (r: builtins.elem r.kind workloadKinds.selectorKinds) resources);

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
              {
                message = "Ingress ${ns}/${ing.metadata.name} routes to Service '${svcName}', which no resource in namespace '${ns}' creates.";
                fix =
                  "Check '${svcName}' for a typo, or add the Service in namespace '${ns}' and reference its .out.name."
                  + "\nIf something outside Kix creates '${svcName}', wrap the name in kix.untrackedRef \"${svcName}\" or declare a kix.mkImport instance.";
              }
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

      # Report whether `r` is the PackageInstance record of an instance under
      # a sentinel key. It sits in `cluster.recordNamespace`, which Kix
      # expects to exist and does not create.
      isSentinelRecord =
        r: r.kind == "PackageInstance" && isSentinelNamespace (r.spec.namespaceName or "");

      uniqueNamespaceFailures =
        let
          missingNs = lib.unique (
            builtins.concatMap (
              r:
              let
                ns = r.metadata.namespace or null;
              in
              if
                ns != null && !(isSentinelNamespace ns) && !(namespaceNames ? ${ns}) && !(isSentinelRecord r)
              then
                [ ns ]
              else
                [ ]
            ) resources
          );
        in
        map (ns: {
          message = "Namespace '${ns}' is used by resources in this build, but no Namespace '${ns}' resource is in the build.";
          fix = "Declare the namespace in your cluster definition:\n  namespaces.${ns} = { };";
        }) missingNs;

      # --- 12. NetworkPolicy podSelector matching ---
      # A NetworkPolicy's podSelector should match at least one workload's pod
      # template labels. An unmatched NetworkPolicy is dead config.

      networkPolicyFailures = builtins.concatMap (
        np:
        let
          selector = np.spec.podSelector or { };
          ns = np.metadata.namespace or "cluster-scoped";
        in
        # An empty selector matches all pods in the namespace.
        if labelSelector.isEmpty selector then
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
            w: nsOf w == ns && mapMatches selector (getPodLabels w)
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

      # Validate that each PodDisruptionBudget selector matches a
      # workload pod template, a ServiceRef selector, or an `operand-of` custom
      # resource.

      pdbFailures = builtins.concatMap (
        pdb:
        let
          selector = pdb.spec.selector or { };
          ns = pdb.metadata.namespace or "cluster-scoped";
          matchesAny = selectsPodsIn ns selector || selectsRefPods ns selector;
          decl = operandOf pdb;
        in
        if labelSelector.isEmpty selector || matchesAny || operandCrPresent pdb then
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
            && mapMatches (svc.spec.selector or { }) podLabels
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
          value = r.metadata.annotations.${kixKeys.rerun} or null;
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
            {
              message = "${w.kind} ${ns}/${w.metadata.name} sets priorityClassName '${pcName}', which no PriorityClass in this cluster creates. Kubernetes would reject its pods at admission.";
              fix =
                "Check '${pcName}' for a typo, or add the PriorityClass to the cluster and reference its .out.name."
                + "\nIf the cluster environment provides '${pcName}', wrap the name in kix.untrackedRef \"${pcName}\" or declare a kix.mkImport instance.";
            }
          ]
      ) workloads;

      # --- 18 & 21. Namespaced kinds and custom resource declarations ---

      inherit
        (validateCrds.checkCrds {
          inherit
            resources
            entries
            dependencyClosure
            ;
        })
        missingNamespaceFailures
        customResourceFailures
        ;

      # --- 19. PersistentVolumeClaim references ---
      # A pod that mounts a claim that does not exist stays Pending.

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
              {
                message = "${w.kind} ${ns}/${w.metadata.name} mounts PersistentVolumeClaim '${claim}', which no resource in namespace '${ns}' creates. Its pods would stay Pending.";
                fix =
                  "Take a persistent-volume-claim instance as a package dependency and mount its .out.name (or kix.mount.pvc)."
                  + "\nIf an operator or the environment creates '${claim}', wrap the name in kix.untrackedRef \"${claim}\" (with by = <creator> when a resource in this build creates it) or declare a kix.mkImport instance.";
              }
            ]
        ) (listOr ((getPodSpec w).volumes or [ ]))
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
            {
              message = "${who} requests StorageClass '${sc}', which no resource or import in this cluster provides. The claim would stay Pending.";
              fix =
                "If '${sc}' is provided by your cluster environment, declare it as an import in your cluster definition (include `roles = [ \"storageClasses\" ];` if it is the cluster's default class):"
                + "\n  instances.kube-system.platform-storage.package = kix.mkImport {"
                + "\n    kind = \"StorageClass\";"
                + "\n    apiVersion = \"storage.k8s.io/v1\";"
                + "\n    roles = [ \"storageClasses\" ];"
                + "\n    out = { name = \"${sc}\"; storageClassName = \"${sc}\"; };"
                + "\n  };"
                + "\nTo use the cluster's default StorageClass instead of hardcoding '${sc}', omit storageClassName on the claim (or read `<storageClasses>.out.storageClassName` from the package's `storageClasses` dependency)."
                + "\nIf something outside Kix provides '${sc}' and you want this build check to skip it without declaring an import, wrap the name in kix.untrackedRef \"${sc}\".";
            }
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
          ) (listOr (sts.spec.volumeClaimTemplates or [ ]))
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
          ) (listOr ((getPodSpec w).volumes or [ ]))
        ) workloads;

      # --- 22. Named Secret and ConfigMap keys ---

      keyFailures = validateKeys.checkKeyReads {
        inherit
          workloads
          byId
          importIds
          externalNames
          ;
      };

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
          annotated = keys: e: builtins.any (key: (e.r.metadata.annotations.${key} or null) == "true") keys;
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

      # --- 24. Jobs do not delete themselves ---
      # A Job that Kubernetes deletes after it finishes looks missing to every
      # comparison with the live cluster, so the operator and a baseline read
      # from the cluster would run it again. A finished Job stays until a
      # later build drops it, and prune deletes it then. A CronJob's
      # jobTemplate may keep the field: Kubernetes creates those Jobs.

      jobTtlFailures = map (
        job:
        let
          ns = job.metadata.namespace or "cluster-scoped";
        in
        "Job ${ns}/${job.metadata.name} sets ttlSecondsAfterFinished, so Kubernetes would delete it after it finishes and Kix would run it again on the next deploy. Remove ttlSecondsAfterFinished. Kix deletes the Job when a later build no longer contains it."
      ) (builtins.filter (r: r.kind == "Job" && (r.spec or { }) ? ttlSecondsAfterFinished) resources);

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
        ++ defaultFailures
        ++ jobTtlFailures;
    in
    allFailures;
}
