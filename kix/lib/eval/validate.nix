# Cross-resource integrity checks over a cluster's finished manifests.
#
# `crossResourceFailures { manifests, externalNames ? { } }` returns a list
# of human-readable failure strings (empty when the set is consistent).
# `externalNames` is the set of "<namespace>/<name>" keys packages marked
# with `kix.untrackedRef`: buildCluster collects them from string context
# before it is stripped, so a reference the author declared external
# resolves. Import markers in the manifest set (PackageInstance with
# `kix.run/import-kind` and `kix.run/import-name`, from
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

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
in
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
      # PackageInstance carrying kix.run/import-kind and kix.run/import-name
      # (scope.mkServiceRef, scope.mkSecretRef, mkImportMarker). The deploy
      # engine gates on the described object, so a reference to it resolves.
      importIds = builtins.listToAttrs (
        builtins.concatMap (
          r:
          let
            anns = r.metadata.annotations or { };
            kind = anns.${kixKeys.importKind} or null;
            iname = anns.${kixKeys.importName} or null;
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
      # namespaced bucket first; the cluster-scoped bucket only for a kind
      # that is cluster-scoped (a RoleBinding may name a ClusterRole). A
      # name the author wrapped in `kix.untrackedRef` is external by
      # declaration and resolves whatever its kind.
      hasResource =
        kind: ns: name:
        byId ? "${kind}/${ns}/${name}"
        || (isClusterScopedKind kind && byId ? "${kind}/cluster-scoped/${name}")
        || importIds ? "${kind}/${ns}/${name}"
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
        # Empty selector matches all pods in the namespace — always valid.
        if selector == { } then
          [ ]
        else if selectsPodsIn ns selector || selectsRefPods ns selector then
          [ ]
        else
          [
            "NetworkPolicy ${ns}/${np.metadata.name} podSelector ${builtins.toJSON selector} matches no workload pod template in namespace ${ns}. Check the selector against the intended workload's pod labels"
          ]
      ) (builtins.filter (r: r.kind == "NetworkPolicy") resources);

      # --- 13. Service port name → container port name consistency ---
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

      # --- 14. PodDisruptionBudget selector → pod template matching ---
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
      # admission, so the workload applies and then never schedules. kubevirt
      # shipped that way, and the openebs ZFS and LVM drivers named four
      # classes the package never built. PriorityClass is cluster-scoped, so
      # `hasResource` finds one built anywhere in the cluster; the `system-`
      # classes ship with Kubernetes itself.

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
        ++ priorityClassFailures;
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
      throw "cluster '${clusterName}' has invalid resource references or configuration:\n${
        lib.concatMapStringsSep "\n" (f: "  - ${f}") failures
      }";
}
