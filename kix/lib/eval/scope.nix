# Scope — per-instance context injected into packages.
# Contains mkResource, mkClusterResource, workload builders, CRD support.

{
  lib,
  k8s,
  rbac,
  crd,
  netpol,
  helpers,
  helm ? { },
}:

let
  inherit (k8s) clusterScoped;
  inherit (helpers) collectTypedAttrs;

  # Capability check helpers. Called at resource construction time.
  # `throw` for hard failures (resource will definitely not work),
  # `builtins.trace` for warnings (resource works but may not behave as expected).
  checkCapability =
    {
      capabilities,
      cap,
      message,
    }:
    if capabilities == { } then
      # No capabilities provided (e.g. tests, standalone scope) — skip checks
      null
    else if !(capabilities.${cap} or true) then
      throw message
    else
      null;
in

rec {
  # Per-instance context injected into packages.
  mkScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      namespaces ? { },
      clusterLabels ? { },
      labelStyle ? "kix",
      selectorLabelsOverride ? null,
      clusterDomain ? "cluster.local",
      capabilities ? { },
      # Handle to the network-policy enforcer's `out` (see
      # kix/lib/eval/cluster.nix → enforcerOut). Exposes `cnpCrdRef` which
      # kix/lib/netpol.nix routes every generated CiliumNetworkPolicy through
      # so the CNP → CRD marker → enforcer root edge is installed
      # automatically. Null when no enforcer is declared or when this scope
      # belongs to the enforcer itself (self-dep guard). See v2_discussions/83.
      networkPolicyEnforcer ? null,
      # Cluster-level networkPolicy submodule (from clusterConfig). Consumed
      # by `mkWorkload` to decide whether per-workload CNPs are emitted at
      # resource-construction time, and by `buildWorkloadCnps` for the
      # `directions` knob. Defaults to disabled.
      networkConfig ? {
        enable = false;
      },
      # Cross-package resources (from `resolvedDepMeta`) that participate
      # in the per-workload Service-edge registry. `scope.mkDeployment`
      # intersects the workload's JSON context against this registry to
      # discover egress targets, exactly the way `processInstance` does it
      # today — just one fixpoint layer earlier. Default empty (no deps).
      depResourcesForNetpol ? [ ],
      # Peeked `packageMeta` (from `meta.peekPackageMeta`) — threaded in so
      # `mkWorkload` can honor `meta.network.intents` (declarative
      # connectivity) and `meta.network.externalIngressEntities` at
      # resource-construction time without waiting for the package's
      # `build` function to return.
      peekedPackageMeta ? { },
      # When true, per-workload CNP emission is disabled for this scope.
      # Set by cluster.nix for the enforcer's own scope so the enforcer's
      # workloads don't declare CNPs that depend on the enforcer itself.
      skipWorkloadNetpol ? false,
      # DNS instance root resource. Passed to `buildWorkloadCnps` which
      # injects it as an extraDep on workloads that reference cross-instance
      # Services (detected via store-path context). Null when no DNS
      # instance is declared or self-dep fires.
      dnsRoot ? null,
    }:
    let
      selectorLabels =
        if selectorLabelsOverride != null then
          selectorLabelsOverride
        else if labelStyle == "helm" then
          {
            app = instanceName;
            release = instanceName;
          }
        else
          {
            "app.kubernetes.io/name" = instanceName;
            "app.kubernetes.io/instance" = instanceName;
          };

      instanceLabels =
        if labelStyle == "helm" then
          {
            release = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          }
        else
          {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };

      # Whether CNP generation is enabled at scope level. Per-workload
      # hostNetwork is checked inside buildWorkloadCnps.
      _shouldGenerateCnps = (networkConfig.enable or false) && !skipWorkloadNetpol;

      # --- Capability checks (evaluated lazily via builtins.seq) ---

      checkLoadBalancer =
        args:
        let
          specType = args.spec.type or (args.extra.spec.type or null);
        in
        if (args.kind or "") == "Service" && specType == "LoadBalancer" then
          checkCapability {
            inherit capabilities;
            cap = "loadBalancer";
            message =
              "[${instanceName}] Service '${args.name or "unknown"}' uses type=LoadBalancer "
              + "but cluster.capabilities.loadBalancer is false. "
              + "Use type=ClusterIP or NodePort, install a LoadBalancer controller, "
              + "or set cluster.capabilities.loadBalancer = true.";
          }
        else
          null;

      checkPrivileged =
        templateSpec:
        let
          containers = templateSpec.containers or [ ];
          initContainers = templateSpec.initContainers or [ ];
          allContainers = containers ++ initContainers;
          hasPrivileged = builtins.any (c: (c.securityContext.privileged or false) == true) allContainers;
          hasHostNetwork = templateSpec.hostNetwork or false;
          hasHostPID = templateSpec.hostPID or false;
          volumes = templateSpec.volumes or [ ];
          hostPathVols = builtins.filter (v: v ? hostPath) volumes;
          hasHostPath = hostPathVols != [ ];
          reason =
            if hasHostNetwork then
              "hostNetwork: true"
            else if hasHostPID then
              "hostPID: true"
            else if hasHostPath then
              "hostPath volume '${(builtins.head hostPathVols).name or "?"}' → ${
                (builtins.head hostPathVols).hostPath.path or "?"
              }"
            else
              "securityContext.privileged: true";
        in
        if hasPrivileged || hasHostNetwork || hasHostPID || hasHostPath then
          checkCapability {
            inherit capabilities;
            cap = "privilegedContainers";
            message =
              "[${instanceName}] Workload uses ${reason} "
              + "but cluster.capabilities.privilegedContainers is false. "
              + "This cluster (e.g. GKE Autopilot, OpenShift) restricts privileged workloads.";
          }
        else
          null;

      scopeMkResource =
        {
          labels ? { },
          ...
        }@args:
        builtins.seq (checkLoadBalancer args) (
          k8s.mkResource (
            removeAttrs args [ "labels" ]
            // {
              namespace = namespaceResource;
              inherit clusterDomain;
              labels = clusterLabels // instanceLabels // labels;
            }
          )
          // {
            packageLabels = labels;
          }
        );

      # WARNING: StatefulSet.spec.serviceName must use .name (plain string),
      # NOT .out.name (context-carrying). Using .out.name creates a store DAG
      # edge to the Service. If the Service also has `requires` pointing back
      # to the StatefulSet, this causes infinite recursion during evaluation.
      # The serviceName field is a plain K8s name match, not a dependency.
      checkDaemonSet =
        kind:
        if kind == "DaemonSet" then
          checkCapability {
            inherit capabilities;
            cap = "daemonSets";
            message =
              "[${instanceName}] DaemonSet cannot be deployed — "
              + "cluster.capabilities.daemonSets is false. "
              + "This cluster (e.g. GKE Autopilot) does not support DaemonSets.";
          }
        else
          null;

      # Validate that all references in a pod spec to namespaced resources
      # (Secrets, ConfigMaps, PVCs, ServiceAccounts, imagePullSecrets) are:
      #   1. DI-tracked (the reference name carries Nix string context —
      #      came from resource.out.* or kix.untrackedRef, not a raw string
      #      literal), AND
      #   2. Same-namespace as the consuming workload (K8s does not allow
      #      cross-namespace mounts / env refs / SA refs).
      #
      # The namespace lives in the `_kix.namespace` reserved-key marker that
      # kix helpers stamp on each fragment (envFrom entry, env entry, volume
      # entry, spec.template.spec via serviceAccount shorthand). stripKixMeta
      # in mkResource removes it before serialization. Fragments without a
      # `_kix` marker (e.g. raw strings wrapped via kix.untrackedRef, or
      # fields not built by a kix helper) only get the DI-tracking check.
      checkNamespacedRefs =
        templateSpec:
        let
          allContainers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);

          # `fragment` is the attrset that carries the optional `_kix` marker
          # (volume entry, envFrom entry, env entry, etc.). `refName` is the
          # context-bearing name string used for the untracked check.
          # `kind` is a human-readable category for diagnostic messages.
          validate =
            kind: fieldDesc: fragment: refName:
            let
              plainName = builtins.unsafeDiscardStringContext refName;
              refNs = fragment._kix.namespace or null;
              refReflected = fragment._kix.reflected or false;
            in
            if builtins.getContext refName == { } then
              throw "[${instanceName}] Untracked ${kind} reference in ${fieldDesc}: "
              + "\"${plainName}\". "
              + "Use resource.out.name / resource.out.* helpers, "
              + "or kix.untrackedRef to opt out explicitly."
            else if refNs != null && refNs != namespaceName && !refReflected then
              throw "[${instanceName}] Cross-namespace ${kind} reference in ${fieldDesc}: "
              + "${kind} \"${plainName}\" is declared in namespace \"${refNs}\" "
              + "but the consuming workload is in namespace \"${namespaceName}\". "
              + "Kubernetes does not allow cross-namespace ${kind} references — "
              + "create or mirror the ${kind} in \"${namespaceName}\" "
              + "(e.g. via scope.forNamespace \"${namespaceName}\"), "
              + "or replicate it with an ExternalSecret / Reflector "
              + "(producers can opt in via `scope.mkSecretRef { reflect = true; }`)."
            else
              null;

          # --- Volumes ---

          volumeChecks = builtins.concatMap (
            v:
            (lib.optional (v ? secret) (validate "secret" "volumes[].secret.secretName" v v.secret.secretName))
            ++ (lib.optional (v ? configMap) (
              validate "configMap" "volumes[].configMap.name" v v.configMap.name
            ))
            ++ (lib.optional (v ? persistentVolumeClaim) (
              validate "pvc" "volumes[].persistentVolumeClaim.claimName" v v.persistentVolumeClaim.claimName
            ))
          ) (templateSpec.volumes or [ ]);

          # --- envFrom / env (secret refs only; configMapRef could be added similarly) ---

          envFromChecks = builtins.concatMap (
            c:
            builtins.concatMap (
              ef:
              (lib.optional (ef ? secretRef) (
                validate "secret" "envFrom[].secretRef.name in container '${c.name}'" ef ef.secretRef.name
              ))
              ++ (lib.optional (ef ? configMapRef) (
                validate "configMap" "envFrom[].configMapRef.name in container '${c.name}'" ef ef.configMapRef.name
              ))
            ) (c.envFrom or [ ])
          ) allContainers;

          keyRefChecks = builtins.concatMap (
            c:
            builtins.concatMap (
              e:
              if (e ? valueFrom) && (e.valueFrom ? secretKeyRef) then
                [
                  (validate "secret" "env '${e.name}' secretKeyRef in container '${c.name}'" e
                    e.valueFrom.secretKeyRef.name
                  )
                ]
              else if (e ? valueFrom) && (e.valueFrom ? configMapKeyRef) then
                [
                  (validate "configMap" "env '${e.name}' configMapKeyRef in container '${c.name}'" e
                    e.valueFrom.configMapKeyRef.name
                  )
                ]
              else
                [ ]
            ) (c.env or [ ])
          ) allContainers;

          # --- imagePullSecrets (typically raw names — DI-tracking only unless marker set) ---

          pullSecretChecks = map (ps: validate "secret" "imagePullSecrets[].name" ps ps.name) (
            templateSpec.imagePullSecrets or [ ]
          );

          # --- serviceAccountName ---
          # If present, must be DI-tracked. Namespace check only fires when a
          # `_kix.serviceAccountNamespace` marker was stamped on templateSpec
          # (via the `serviceAccount = saResource` shorthand in mkWorkload).
          saChecks =
            if templateSpec ? serviceAccountName then
              let
                saName = templateSpec.serviceAccountName;
                plainName = builtins.unsafeDiscardStringContext saName;
                saNs = templateSpec._kix.serviceAccountNamespace or null;
              in
              if builtins.getContext saName == { } then
                [
                  (
                    throw "[${instanceName}] Untracked serviceAccount reference in spec.template.spec.serviceAccountName: "
                    + "\"${plainName}\". "
                    + "Use `serviceAccount = self.serviceAccount;` (kix shorthand that also enables "
                    + "cross-namespace validation) or kix.untrackedRef for external SAs."
                  )
                ]
              else if saNs != null && saNs != namespaceName then
                [
                  (
                    throw "[${instanceName}] Cross-namespace serviceAccount reference: "
                    + "ServiceAccount \"${plainName}\" is declared in namespace \"${saNs}\" "
                    + "but the consuming workload is in namespace \"${namespaceName}\". "
                    + "Kubernetes requires a Pod's ServiceAccount to live in the Pod's own namespace."
                  )
                ]
              else
                [ null ]
            else
              [ ];

          allChecks = volumeChecks ++ envFromChecks ++ keyRefChecks ++ pullSecretChecks ++ saChecks;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;

      # Validate that spec.selector.matchLabels is a subset (keys + values)
      # of spec.template.metadata.labels. A mismatch produces a Deployment/
      # StatefulSet/DaemonSet that "deploys" but never matches its own pods
      # because the controller's label-selector can't find them.
      #
      # Only runs when the user supplied their own template labels (the
      # default path in mkWorkload copies selector → labels, which is
      # trivially a subset).
      checkSelectorSubset =
        selector: userTemplateLabels: kind:
        let
          missingKeys = lib.filter (k: !(userTemplateLabels ? ${k})) (builtins.attrNames selector);
          mismatchedKeys = lib.filter (
            k: userTemplateLabels ? ${k} && (toString userTemplateLabels.${k}) != (toString selector.${k})
          ) (builtins.attrNames selector);
          fmt =
            labels:
            "{ ${builtins.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k}=${toString v}") labels)} }";
        in
        if missingKeys != [ ] then
          throw "[${instanceName}] ${kind} spec.selector.matchLabels ⊄ spec.template.metadata.labels: "
          + "selector key(s) ${builtins.concatStringsSep ", " missingKeys} are missing from template labels. "
          + "selector=${fmt selector} templateLabels=${fmt userTemplateLabels}. "
          + "A Deployment's controller uses selector to find pods built from template — "
          + "mismatched keys make the workload deploy pods it can't manage."
        else if mismatchedKeys != [ ] then
          throw "[${instanceName}] ${kind} spec.selector.matchLabels value mismatch on key(s) "
          + "${builtins.concatStringsSep ", " mismatchedKeys}: "
          + "selector=${fmt selector} templateLabels=${fmt userTemplateLabels}."
        else
          null;

      # Collect all named container ports from a templateSpec.
      # Returns list of { containerName, portName, containerPort }.
      _collectPortNames =
        templateSpec:
        let
          allContainers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);
        in
        builtins.concatMap (
          c:
          map (p: {
            containerName = c.name;
            portName = p.name or null;
            containerPort = p.containerPort or null;
          }) (builtins.filter (p: p ? name) (c.ports or [ ]))
        ) allContainers;

      # Validate that any named port referenced by a probe (livenessProbe,
      # readinessProbe, startupProbe) resolves to a container port in the
      # same container. Integer ports are allowed through without check.
      checkNamedPorts =
        templateSpec:
        let
          containers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);

          # Per-container set of declared named ports.
          containerPortNames = c: map (p: p.name) (builtins.filter (p: p ? name) (c.ports or [ ]));

          probes = c: [
            {
              name = "livenessProbe";
              value = c.livenessProbe or null;
            }
            {
              name = "readinessProbe";
              value = c.readinessProbe or null;
            }
            {
              name = "startupProbe";
              value = c.startupProbe or null;
            }
          ];

          # Extract the named port from a probe, if any.
          probePortName =
            probe:
            if probe == null then
              null
            else if probe ? httpGet && probe.httpGet ? port && builtins.isString probe.httpGet.port then
              probe.httpGet.port
            else if probe ? tcpSocket && probe.tcpSocket ? port && builtins.isString probe.tcpSocket.port then
              probe.tcpSocket.port
            else if probe ? grpc && probe.grpc ? port && builtins.isString probe.grpc.port then
              probe.grpc.port
            else
              null;

          containerChecks = builtins.concatMap (
            c:
            let
              names = containerPortNames c;
            in
            builtins.concatMap (
              p:
              let
                portName = probePortName p.value;
              in
              if portName == null then
                [ ]
              else if !(builtins.elem portName names) then
                [
                  (
                    throw "[${instanceName}] Container '${c.name}' ${p.name} references named port "
                    + "\"${portName}\" which is not declared by the container. "
                    + "Declared named ports: [${builtins.concatStringsSep ", " names}]. "
                    + "Add `ports = [ (kix.port \"${portName}\" <N>) ]` or use a numeric port."
                  )
                ]
              else
                [ null ]
            ) (probes c)
          ) containers;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null containerChecks;

      # Parse a K8s resource quantity ("100m", "1", "128Mi", "1Gi", "1.5")
      # into a comparable rational number. CPU uses milli-cores, memory
      # uses bytes. Returns null for unparseable strings so the check
      # silently skips them (custom units etc.).
      _parseQuantity =
        resource: q:
        let
          str = builtins.unsafeDiscardStringContext (toString q);
          # CPU:  "100m" = 100, "1" = 1000, "1.5" = 1500
          cpuMilli = builtins.match "([0-9]+)m" str;
          cpuPlainInt = builtins.match "([0-9]+)" str;
          cpuDecimal = builtins.match "([0-9]+)\\.([0-9]+)" str;
          # Memory: Ki, Mi, Gi, Ti, Pi, Ei (binary) and K, M, G, T, P, E (decimal)
          memBin = builtins.match "([0-9]+)(Ki|Mi|Gi|Ti|Pi|Ei)" str;
          memDec = builtins.match "([0-9]+)(K|M|G|T|P|E)" str;
          memPlain = builtins.match "([0-9]+)" str;
          binMult =
            s:
            {
              Ki = 1024;
              Mi = 1024 * 1024;
              Gi = 1024 * 1024 * 1024;
              Ti = 1024 * 1024 * 1024 * 1024;
              Pi = 1024 * 1024 * 1024 * 1024 * 1024;
              Ei = 1024 * 1024 * 1024 * 1024 * 1024 * 1024;
            }
            .${s};
          decMult =
            s:
            {
              K = 1000;
              M = 1000000;
              G = 1000000000;
              T = 1000000000000;
              P = 1000000000000000;
              E = 1000000000000000000;
            }
            .${s};
        in
        if resource == "cpu" then
          if cpuMilli != null then
            builtins.fromJSON (builtins.head cpuMilli)
          else if cpuDecimal != null then
            let
              whole = builtins.fromJSON (builtins.elemAt cpuDecimal 0);
              frac = builtins.elemAt cpuDecimal 1;
              # normalize frac to 3 digits (milli)
              fracPadded = builtins.substring 0 3 (frac + "000");
              fracInt = builtins.fromJSON fracPadded;
            in
            whole * 1000 + fracInt
          else if cpuPlainInt != null then
            (builtins.fromJSON (builtins.head cpuPlainInt)) * 1000
          else
            null
        else
        # memory
        if memBin != null then
          (builtins.fromJSON (builtins.elemAt memBin 0)) * (binMult (builtins.elemAt memBin 1))
        else if memDec != null then
          (builtins.fromJSON (builtins.elemAt memDec 0)) * (decMult (builtins.elemAt memDec 1))
        else if memPlain != null then
          builtins.fromJSON (builtins.head memPlain)
        else
          null;

      # Validate that resources.limits ≥ resources.requests per container,
      # for cpu and memory. Unparseable quantities are skipped (fallback).
      checkContainerResources =
        templateSpec:
        let
          allContainers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);
          checkOne =
            c:
            let
              limits = c.resources.limits or { };
              requests = c.resources.requests or { };
              checkRes =
                res:
                if !(limits ? ${res}) || !(requests ? ${res}) then
                  null
                else
                  let
                    l = _parseQuantity res limits.${res};
                    r = _parseQuantity res requests.${res};
                  in
                  if l == null || r == null then
                    null
                  else if l < r then
                    throw "[${instanceName}] Container '${c.name}' resources.limits.${res} (${toString limits.${res}}) < resources.requests.${res} (${toString requests.${res}}). "
                    + "Kubernetes rejects limits < requests at admission."
                  else
                    null;
            in
            [
              (checkRes "cpu")
              (checkRes "memory")
            ];
          allChecks = builtins.concatMap checkOne allContainers;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;

      # Validate that container names, env var names within each container,
      # volume names within the pod, and named ports within each container
      # are unique. K8s rejects duplicates at admission time (or accepts
      # and silently keeps the last occurrence — both are surprising).
      checkDuplicateNames =
        templateSpec:
        let
          containers = templateSpec.containers or [ ];
          initContainers = templateSpec.initContainers or [ ];
          allContainers = containers ++ initContainers;
          volumes = templateSpec.volumes or [ ];

          dups =
            names:
            let
              sorted = lib.sort (a: b: a < b) names;
              go =
                seen: rest:
                if rest == [ ] then
                  seen
                else
                  let
                    x = builtins.head rest;
                    xs = builtins.tail rest;
                  in
                  if xs != [ ] && x == (builtins.head xs) then go (seen ++ [ x ]) (builtins.tail xs) else go seen xs;
            in
            lib.unique (go [ ] sorted);

          containerNameDups = dups (map (c: c.name) allContainers);
          volumeNameDups = dups (map (v: v.name) volumes);

          envDups = builtins.concatMap (
            c:
            let
              envNames = map (e: e.name) (c.env or [ ]);
              d = dups envNames;
            in
            if d == [ ] then
              [ ]
            else
              [
                (
                  throw "[${instanceName}] Container '${c.name}' has duplicate env var name(s): "
                  + "[${builtins.concatStringsSep ", " d}]."
                )
              ]
          ) allContainers;

          portDups = builtins.concatMap (
            c:
            let
              portNames = map (p: p.name) (builtins.filter (p: p ? name) (c.ports or [ ]));
              d = dups portNames;
            in
            if d == [ ] then
              [ ]
            else
              [
                (
                  throw "[${instanceName}] Container '${c.name}' has duplicate named port(s): "
                  + "[${builtins.concatStringsSep ", " d}]."
                )
              ]
          ) allContainers;

          containerNameCheck =
            if containerNameDups != [ ] then
              throw "[${instanceName}] Pod has duplicate container name(s): "
              + "[${builtins.concatStringsSep ", " containerNameDups}]. "
              + "Container names must be unique within a pod."
            else
              null;

          volumeNameCheck =
            if volumeNameDups != [ ] then
              throw "[${instanceName}] Pod has duplicate volume name(s): "
              + "[${builtins.concatStringsSep ", " volumeNameDups}]. "
              + "Volume names must be unique within a pod (common cause: "
              + "multiple mounts auto-derived from resources with the same name)."
            else
              null;

          allChecks = [
            containerNameCheck
            volumeNameCheck
          ]
          ++ envDups
          ++ portDups;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;

      # Validate that env[].valueFrom.fieldRef.fieldPath uses one of the
      # K8s-supported downward-API paths. K8s silently fails pod creation
      # with a cryptic error on unsupported paths.
      _allowedFieldPaths = [
        "metadata.name"
        "metadata.namespace"
        "metadata.uid"
        "metadata.labels"
        "metadata.annotations"
        "spec.nodeName"
        "spec.serviceAccountName"
        "status.hostIP"
        "status.podIP"
        "status.podIPs"
      ];

      checkFieldRefs =
        templateSpec:
        let
          allContainers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);

          # Supports `metadata.labels['key']` and `metadata.annotations['key']` variants.
          isAllowed =
            path:
            builtins.elem path _allowedFieldPaths
            || builtins.match "metadata\\.labels\\['.*'\\]" path != null
            || builtins.match "metadata\\.annotations\\['.*'\\]" path != null;

          checksPerContainer =
            c:
            builtins.concatMap (
              e:
              if (e ? valueFrom) && (e.valueFrom ? fieldRef) then
                let
                  fp = e.valueFrom.fieldRef.fieldPath or null;
                in
                if fp != null && !(isAllowed fp) then
                  [
                    (
                      throw "[${instanceName}] env '${e.name}' in container '${c.name}' uses "
                      + "unsupported fieldRef.fieldPath \"${fp}\". Allowed: "
                      + "${builtins.concatStringsSep ", " _allowedFieldPaths}, "
                      + "metadata.labels['<key>'], metadata.annotations['<key>']."
                    )
                  ]
                else
                  [ null ]
              else
                [ ]
            ) (c.env or [ ]);

          allChecks = builtins.concatMap checksPerContainer allContainers;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;

      # Expand the `serviceAccount = saResource` shorthand on a templateSpec:
      # sets `serviceAccountName` from the SA resource's out.name and stamps
      # `_kix.serviceAccountNamespace` so checkNamespacedRefs can validate
      # cross-namespace use. The `serviceAccount` field is stripped from
      # the returned templateSpec (stripKixMeta handles `_kix` later).
      _expandServiceAccount =
        templateSpec:
        if !(templateSpec ? serviceAccount) then
          templateSpec
        else
          let
            sa = templateSpec.serviceAccount;
            saNs =
              if (sa.namespace._type or "") == "k8s-cluster-scoped" then null else sa.namespace.name or null;
            existingKix = templateSpec._kix or { };
          in
          if sa == null then
            removeAttrs templateSpec [ "serviceAccount" ]
          else
            (removeAttrs templateSpec [ "serviceAccount" ])
            // {
              serviceAccountName = sa.out.name;
              _kix =
                existingKix
                // lib.optionalAttrs (saNs != null) {
                  serviceAccountNamespace = saNs;
                };
            };

      # Expand the `headlessService = svcResource` shorthand for StatefulSet:
      # reads svc.name (plain, no context — avoiding the recursion described
      # in the warning above) and sets spec.serviceName accordingly. Also
      # validates same-namespace at build time.
      _expandHeadlessService =
        spec:
        if !(spec ? headlessService) then
          spec
        else
          let
            svc = spec.headlessService;
            svcNs =
              if (svc.namespace._type or "") == "k8s-cluster-scoped" then null else svc.namespace.name or null;
          in
          if svc == null then
            removeAttrs spec [ "headlessService" ]
          else if (svc._type or "") != "k8s-resource" || svc.kind or "" != "Service" then
            throw "[${instanceName}] mkStatefulSet headlessService must be a Service resource "
            + "(got ${svc._type or "non-resource"}, kind=${svc.kind or "?"})"
          else if svcNs != null && svcNs != namespaceName then
            throw "[${instanceName}] StatefulSet headlessService '${svc.name}' is in namespace "
            + "\"${svcNs}\" but the StatefulSet is in namespace \"${namespaceName}\"."
          else
            (removeAttrs spec [ "headlessService" ])
            // {
              # Plain name — no string context → no DAG edge → no recursion
              # when the Service also requires this StatefulSet (rare but
              # the warning on checkDaemonSet above describes why this matters).
              serviceName = svc.name;
            };

      # Lazy cross-package Service registry (path → Service resource).
      # Used by `mkWorkload` to discover egress edges from the workload's
      # raw JSON context before the workload resource is constructed.
      # Built from `depResourcesForNetpol`, which instance.nix populates
      # from `resolvedDepMeta`. Evaluated at most once (Nix laziness).
      _netpolServiceRegistry = netpol.mkServiceRegistry depResourcesForNetpol;

      # ServiceRef registry (path → endpoint metadata) for operator-managed
      # Services referenced via scope.mkServiceRef. Same source list as the
      # Service registry — ServiceRef markers are PackageInstance resources
      # that live alongside regular dep resources.
      _netpolServiceRefRegistry = netpol.mkServiceRefRegistry depResourcesForNetpol;

      mkWorkload =
        apiVersion: kind: attrs:
        let
          rawSpec = attrs.spec or { };
          spec = if kind == "StatefulSet" then _expandHeadlessService rawSpec else rawSpec;
          selector =
            spec.selector.matchLabels
              or (throw "mkWorkload (${kind}): spec.selector.matchLabels is required — use scope.selectorLabels");
          templateMeta = spec.template.metadata or { };
          rawTemplateSpec = spec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          # Default: copy selector into template labels. When user supplies
          # template labels explicitly, validate selector ⊆ labels instead.
          userSuppliedLabels = templateMeta ? labels;
          effectiveTemplateLabels = if userSuppliedLabels then templateMeta.labels else selector;

          hostNetwork = templateSpec.hostNetwork or false;

          # Canonical spec that both the pre-build CNP extraction and the
          # final mkResource call see — identical shape, identical context.
          # This matches the structure scopeMkResource would receive in its
          # args.spec, ensuring the JSON context we walk for service edges
          # is the exact same context the workload resource carries.
          finalSpec =
            removeAttrs spec [
              "selector"
              "template"
            ]
            // {
              selector.matchLabels = selector;
              template = {
                metadata = templateMeta // {
                  labels = effectiveTemplateLabels;
                };
                spec = templateSpec;
              };
            };

          baseArgs = removeAttrs attrs [ "spec" ] // {
            inherit apiVersion kind;
            spec = finalSpec;
          };

          # Service-edge analysis + conditional CNP emission. Always runs
          # (DNS deps are unconditional); CNPs are generated only when
          # netpol is enabled. See v2_discussions/83 and v2_discussions/94.
          workloadDeps = netpol.buildWorkloadCnps {
            scope = scopeObj;
            inherit instanceName namespaceName;
            workloadInput = baseArgs;
            workloadKind = kind;
            wSelector = selector;
            inherit hostNetwork dnsRoot;
            serviceRegistry = _netpolServiceRegistry;
            serviceRefRegistry = _netpolServiceRefRegistry;
            inherit networkConfig;
            networkPolicyEnforcer = if _shouldGenerateCnps then networkPolicyEnforcer else null;
            packageIntents = (peekedPackageMeta.network or { }).intents or { };
          };

          # CNPs and DNS deps are hard prerequisites — the workload must
          # not run before its network policies exist. Use `requires` (not
          # `extraDeps`) so kix deploy treats them as ordering constraints.
          netpolRequires = workloadDeps.cnps ++ workloadDeps.dnsDeps;

          # Strip _helmNetworkDeps before building the resource — it was
          # only needed for store-path context in buildWorkloadCnps above.
          # k8s.mkResource does not accept unknown fields.
          workload = scopeMkResource (
            removeAttrs baseArgs [ "_helmNetworkDeps" ]
            // {
              requires = (attrs.requires or [ ]) ++ netpolRequires;
            }
          );
        in
        builtins.seq (checkDaemonSet kind) (
          builtins.seq (checkPrivileged templateSpec) (
            builtins.seq
              (if userSuppliedLabels then checkSelectorSubset selector templateMeta.labels kind else null)
              (
                builtins.seq (checkNamespacedRefs templateSpec) (
                  builtins.seq (checkNamedPorts templateSpec) (
                    builtins.seq (checkContainerResources templateSpec) (
                      builtins.seq (checkDuplicateNames templateSpec) (
                        builtins.seq (checkFieldRefs templateSpec) (
                          # Attach the per-workload CNPs as side-band
                          # metadata. instance.nix drains these off every
                          # workload in `allPartResources` after the parts
                          # fixpoint settles and appends them to the resource
                          # pool (replacing the old `_networkPolicies` bag).
                          # Includes the caller-side paired ingress CNPs
                          # for cross-namespace edges (v2_discussions/83
                          # Phase C) — those live in the target namespace
                          # but are owned by this instance.
                          workload
                          // {
                            _generatedNetpol = workloadDeps.cnps;
                          }
                        )
                      )
                    )
                  )
                )
              )
          )
        );

      # ── Job workload wrapper (CNP generation + validation) ─────────
      #
      # Like mkWorkload but handles Job-specific differences:
      #   - Jobs typically omit spec.selector (auto-generated by the API
      #     server at creation time), so falls back to template labels.
      #   - No headless service expansion.
      #   - Skips DaemonSet capability check and selector⊆labels check.
      #
      # Jobs need per-workload CNPs just like Deployments — without this,
      # a Job created via plain mkResource bypasses buildWorkloadCnps and
      # runs before its DNS/egress/apiserver CNPs are applied.
      mkJob =
        attrs:
        let
          kind = "Job";
          apiVersion = "batch/v1";
          rawSpec = attrs.spec or { };
          # Jobs typically omit spec.selector (auto-generated by the API
          # server at creation time), so fall back to template labels.
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels
              or (throw "mkJob: spec.selector.matchLabels or spec.template.metadata.labels is required");
          templateMeta = rawSpec.template.metadata or { };
          rawTemplateSpec = rawSpec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          hostNetwork = templateSpec.hostNetwork or false;

          # Jobs don't need selector → template label copying (the API
          # server generates the selector at creation time). Keep template
          # labels as-is; only set them from selector if completely absent.
          effectiveTemplateLabels = templateMeta.labels or selector;

          finalSpec =
            removeAttrs rawSpec [
              "selector"
              "template"
            ]
            // lib.optionalAttrs (rawSpec ? selector) {
              selector.matchLabels = selector;
            }
            // {
              template = {
                metadata = templateMeta // {
                  labels = effectiveTemplateLabels;
                };
                spec = templateSpec;
              };
            };

          baseArgs = removeAttrs attrs [ "spec" ] // {
            inherit apiVersion kind;
            spec = finalSpec;
          };

          workloadDeps = netpol.buildWorkloadCnps {
            scope = scopeObj;
            inherit instanceName namespaceName;
            workloadInput = baseArgs;
            workloadKind = kind;
            wSelector = selector;
            inherit hostNetwork dnsRoot;
            serviceRegistry = _netpolServiceRegistry;
            serviceRefRegistry = _netpolServiceRefRegistry;
            inherit networkConfig;
            networkPolicyEnforcer = if _shouldGenerateCnps then networkPolicyEnforcer else null;
            packageIntents = (peekedPackageMeta.network or { }).intents or { };
          };

          netpolRequires = workloadDeps.cnps ++ workloadDeps.dnsDeps;

          workload = scopeMkResource (
            baseArgs
            // {
              requires = (attrs.requires or [ ]) ++ netpolRequires;
            }
          );
        in
        builtins.seq (checkPrivileged templateSpec) (
          builtins.seq (checkNamespacedRefs templateSpec) (
            builtins.seq (checkContainerResources templateSpec) (
              builtins.seq (checkDuplicateNames templateSpec) (
                builtins.seq (checkFieldRefs templateSpec) (
                  workload
                  // {
                    _generatedNetpol = workloadDeps.cnps;
                  }
                )
              )
            )
          )
        );

      # ── Helm workload wrapper (CNP generation, no validation) ───────
      #
      # Like mkWorkload but skips the native-package validation checks
      # (checkNamespacedRefs, checkPrivileged, etc.) which expect DI-tracked
      # references that helm manifests don't have. Only performs:
      #   1. Selector / template extraction
      #   2. Per-workload CNP generation via buildWorkloadCnps
      #   3. _generatedNetpol sideband attachment
      #
      # Called from helm.nix wrapResource for Deployment/StatefulSet/DaemonSet.
      mkHelmWorkload =
        attrs:
        let
          kind = attrs.kind or (throw "mkHelmWorkload: kind is required");
          apiVersion = attrs.apiVersion or "apps/v1";
          rawSpec = attrs.spec or { };
          # Jobs typically omit spec.selector (auto-generated by the API
          # server at creation time), so fall back to template labels.
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels
              or (throw "mkHelmWorkload (${kind}): spec.selector.matchLabels or spec.template.metadata.labels is required");
          hostNetwork = rawSpec.template.spec.hostNetwork or false;

          # Keep _helmNetworkDeps in workloadInput so their store-path
          # context is visible to extractServiceEdgesFromJson. Strip it
          # only before passing to scopeMkResource (k8s.mkResource doesn't
          # accept unknown fields).
          workloadInput = attrs // {
            inherit apiVersion kind;
          };

          workloadDeps = netpol.buildWorkloadCnps {
            scope = scopeObj;
            inherit instanceName namespaceName workloadInput;
            workloadKind = kind;
            wSelector = selector;
            inherit hostNetwork dnsRoot;
            serviceRegistry = _netpolServiceRegistry;
            serviceRefRegistry = _netpolServiceRefRegistry;
            inherit networkConfig;
            networkPolicyEnforcer = if _shouldGenerateCnps then networkPolicyEnforcer else null;
            packageIntents = (peekedPackageMeta.network or { }).intents or { };
          };

          netpolRequires = workloadDeps.cnps ++ workloadDeps.dnsDeps;

          workload = scopeMkResource (
            removeAttrs workloadInput [ "_helmNetworkDeps" ]
            // {
              requires = (workloadInput.requires or [ ]) ++ netpolRequires;
            }
          );
        in
        workload
        // {
          _generatedNetpol = workloadDeps.cnps;
        };

      scopeMkClusterResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = clusterScoped;
            inherit clusterDomain;
            labels = clusterLabels // instanceLabels // labels;
          }
        )
        // {
          packageLabels = labels;
        };

      # ── CRD support ──────────────────────────────────────────────────

      # Create a CRD resource from a K8s-native spec shape.
      # Returns a resource (usable in requires, etc.) with .out.{cr, mkCR}.
      #
      # Accepts the same structure as a real CRD manifest's spec, plus an
      # optional top-level `labels` for the CRD resource metadata.
      # Use crd.fromKind and other transforms to build the input.
      #
      # Example:
      #   crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
      #   |> crd.withShortNames [ "sgclu" ]
      #   |> scope.mkCRD
      mkCRD =
        attrs:
        let
          crdSpec = attrs.spec or (throw "mkCRD: spec is required");
          labels = attrs.labels or { };
          crKind = crdSpec.names.kind;
          group = crdSpec.group;
          plural = crdSpec.names.plural;
          version = (builtins.head crdSpec.versions).name;
          crdScope = crdSpec.scope or "Namespaced";

          crdResource = scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            extra.spec = crdSpec;
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            group = group;
            kind = crKind;
            inherit version crdScope;
          };
        in
        crdResource
        // {
          out = crdResource.out // builders;
        };

      # Shared import marker constructor. Emits a namespaced PackageInstance
      # resource with `kix.dev/mode=import` annotations describing an
      # externally-managed resource. Used by `mkCRDRef` and `mkSecretRef`.
      #
      # The CLI deploy engine's readiness check (cli/kix/src/cluster/readiness.rs)
      # parses these markers into an `ImportTarget` and polls the cluster for
      # the described resource, gating consuming waves until it exists (and
      # for Secrets, until all `expected_keys` are present in `data`).
      #
      # The marker lives in the consumer's namespace. The imported resource is
      # expected in the same namespace (for namespaced kinds) — cross-namespace
      # imports are not supported; use a dedicated adapter instance in the
      # owning namespace and DI the resource handle instead.
      #
      # Arguments:
      #   markerName        - k8s name of the PackageInstance marker
      #   importKind        - kind of the external resource (e.g. "Secret")
      #   importApiVersion  - apiVersion of the external resource (e.g. "v1")
      #   importName        - k8s name of the external resource
      #   extraAnnotations  - additional kix.dev/* annotations (e.g. import-secret-keys)
      #   extraRequires     - additional `requires` edges for wave placement
      mkImportMarker =
        {
          markerName,
          importKind,
          importApiVersion,
          importName,
          extraAnnotations ? { },
          extraRequires ? [ ],
        }:
        scopeMkResource {
          apiVersion = "kix.dev/v1alpha1";
          kind = "PackageInstance";
          name = markerName;
          annotations = {
            "kix.dev/mode" = "import";
            "kix.dev/import-kind" = importKind;
            "kix.dev/import-apiversion" = importApiVersion;
            "kix.dev/import-name" = importName;
          }
          // extraAnnotations;
          # The PackageInstance CRD must exist before any marker can be
          # applied. Callers pass extraRequires for things like `installedBy`
          # (orders the marker AFTER its installer in the wave graph).
          requires = [ k8s.kixCRDs.packageInstance ] ++ extraRequires;
          extra.spec = {
            instanceName = markerName;
            namespaceName = namespaceName;
            mode = "import";
          };
        };

      # Create a CRD reference for externally-managed CRDs (installed by an
      # operator's INSTALL_CRDS bootstrap, helm, or pre-existing on the cluster).
      #
      # Emits a real k8s-resource — a PackageInstance import marker in the
      # caller's namespace. The CLI deploy engine polls for the described CRD
      # and waits until it's `Established=True`, which naturally gates the
      # wave containing any CR built via `.out.mkCR`.
      #
      # Dependency wiring is per-CR: `mkCRDBuilders` auto-adds this marker to
      # every CR's `requires`, so the wave graph places the marker before
      # consuming CRs via the standard forward-closure walker. No `root.requires`
      # plumbing, no special case in wave ordering.
      #
      # `installedBy` accepts either a single resource or a list of resources.
      # Every entry becomes a hard `requires` edge on the marker, so the CR's
      # wave is gated on all of them being Ready — not just being applied.
      # This matters for helm-bundled operators where the CRD is installed by
      # the chart alongside multiple workloads (e.g. cilium-agent DaemonSet
      # + cilium-operator Deployment): the CRD must wait for *every* workload
      # that serves its admission / conversion webhooks, not just a single
      # hand-picked root. See helm.nix's `rootOut { workloads }` plumbing.
      mkCRDRef =
        {
          group,
          kind,
          plural,
          version ? "v1",
          crdScope ? "Namespaced",
          installedBy ? null,
        }:
        let
          crdName = "${plural}.${group}";
          # Sanitize group dots for a k8s-valid name.
          groupSlug = builtins.replaceStrings [ "." ] [ "-" ] group;
          markerName = "crd-ref-${plural}-${groupSlug}";

          installedByList =
            if installedBy == null then
              [ ]
            else if builtins.isList installedBy then
              installedBy
            else
              [ installedBy ];

          marker = mkImportMarker {
            inherit markerName;
            importKind = "CustomResourceDefinition";
            importApiVersion = "apiextensions.k8s.io/v1";
            importName = crdName;
            extraRequires = installedByList;
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = marker;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        marker
        // {
          out = marker.out // builders;
        };

      # Scope-side CRD builder: reads the CRD's scope and auto-routes.
      # Uses scopeObj (lazy self-reference) so crd.out.mkCR gets the full scope.
      mkCR = crd: args: crd.out.mkCR scopeObj args;

      # ── Secret support ──────────────────────────────────────────────

      # Create a kix-managed Secret resource with enriched out API.
      # Accepts inline stringData (for dev/config-derived secrets) or
      # source + hash (for SOPS-encrypted secrets, kix-deploy hydrates).
      #
      # The out API provides: keyRef, mkEnv, envFrom, volume — all with
      # build-time key validation and automatic dependency tracking.
      #
      # Usage:
      #   creds = scope.mkSecret {
      #     name = "db-credentials";
      #     keys = [ "username" "password" ];
      #     stringData = { username = "admin"; password = "s3cret"; };
      #   };
      #   env = creds.out.mkEnv { DB_USER = "username"; DB_PASS = "password"; };
      mkSecret =
        {
          name,
          keys ? null,
          type ? "Opaque",
          stringData ? { },
          source ? null,
          hash ? null,
          meta ? { },
          labels ? { },
          annotations ? { },
          requires ? [ ],
          extra ? { },
        }:
        let
          effectiveKeys =
            if keys != null then
              keys
            else if stringData != { } then
              builtins.attrNames stringData
            else
              throw "mkSecret \"${name}\": either 'keys' or 'stringData' must be provided";

          resource = scopeMkResource {
            apiVersion = "v1";
            kind = "Secret";
            inherit
              name
              labels
              requires
              ;
            annotations =
              annotations
              // {
                "kix.dev/secret-keys" = builtins.concatStringsSep "," effectiveKeys;
              }
              // lib.optionalAttrs (source != null) {
                "kix.dev/sops-source" = toString source;
              }
              // lib.optionalAttrs (hash != null) {
                "kix.dev/content-hash" = hash;
              }
              // lib.optionalAttrs (meta ? classification) {
                "kix.dev/classification" = meta.classification;
              }
              // lib.optionalAttrs (meta ? rotationPolicy) {
                "kix.dev/rotation-policy" = meta.rotationPolicy;
              };
            extra = {
              inherit type;
            }
            // lib.optionalAttrs (stringData != { }) { inherit stringData; }
            // extra;
          };

          resourceCtx = builtins.getContext "${resource}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          secretHelpers = k8s.mkSecretHelpers {
            inherit name type attachCtx;
            keys = effectiveKeys;
            namespace = namespaceName;
          };
        in
        resource // { out = resource.out // secretHelpers; };

      # Reference an externally-managed secret (Vault, ESO, cert-manager, bootstrap).
      #
      # Emits a real k8s-resource — a PackageInstance import marker in the
      # caller's namespace describing the expected Secret. The CLI deploy
      # engine polls for the Secret and validates that every declared key in
      # `keys` is present in `data` before any consuming wave runs, turning
      # build-time key validation into a deploy-time gate.
      #
      # The marker's namespace is the consumer's namespace; the referenced
      # Secret is expected in the same namespace. Cross-namespace access is
      # not supported — use a dedicated adapter instance in the owning
      # namespace and DI the resource handle instead.
      #
      # Same .out.{name, keyRef, mkEnv, envFrom, volume} interface as mkSecret.
      #
      # Usage:
      #   creds = scope.mkSecretRef {
      #     name = "vault-db-creds";
      #     keys = [ "username" "password" ];
      #   };
      #   env = creds.out.mkEnv { DB_USER = "username"; };
      mkSecretRef =
        {
          name,
          keys,
          type ? "Opaque",
          requires ? [ ],
          reflect ? false,
          # When `reflect = true`, the secret is expected to be mirrored
          # cross-namespace by the emberstack reflector controller. Helpers
          # produced from this ref get a `_kix.reflected = true` marker, which
          # tells `checkNamespacedRefs` to permit consumption from any
          # namespace. The producer is still responsible for ensuring the
          # source secret carries reflector annotations (typically by
          # emitting a one-shot annotator Job alongside this ref).
        }:
        let
          # Guard the shape of `keys`. Empty list is intentionally allowed:
          # external secrets referenced via envFrom/volume only (keys unknown
          # to kix) are a legitimate pattern — `keyRef` on such a ref still
          # throws a clear "does not declare key" message at use site. When
          # keys is empty, the CLI skips the key-presence check and only
          # verifies that the Secret exists.
          _ =
            if !(builtins.isList keys) then
              throw "mkSecretRef \"${name}\": 'keys' must be a list of strings (got ${builtins.typeOf keys})"
            else
              null;

          # Marker name is prefixed with instanceName so two instances in the
          # same namespace can both reference the same external secret without
          # PackageInstance collisions on kubectl apply.
          markerName = "secret-ref-${instanceName}-${name}";

          marker = builtins.seq _ (mkImportMarker {
            inherit markerName;
            importKind = "Secret";
            importApiVersion = "v1";
            importName = name;
            extraAnnotations = {
              "kix.dev/secret-type" = type;
            }
            // lib.optionalAttrs (keys != [ ]) {
              "kix.dev/import-secret-keys" = builtins.concatStringsSep "," keys;
            };
            extraRequires = requires;
          });

          # Derive context from the marker resource so consumers that reference
          # the Secret through envFrom / keyRef / volume get a forward-closure
          # edge to the marker. This mirrors mkSecret's pattern (scope.nix:1003)
          # and replaces the old `builtins.toFile` store-path trick.
          resourceCtx = builtins.getContext "${marker}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          secretHelpers = k8s.mkSecretHelpers {
            inherit
              name
              keys
              type
              attachCtx
              ;
            namespace = namespaceName;
            reflected = reflect;
          };
        in
        marker
        // {
          # Override the marker's auto-derived out wholesale: the marker's
          # own name/fqdn point at the PackageInstance, not the referenced
          # Secret. Consumers need `out.name` to carry the Secret's real name
          # (with marker context so the dep edge is still tracked).
          out = {
            name = attachCtx name;
          }
          // secretHelpers;
        };

      # Reference an operator-managed Service (not created by kix).
      #
      # Emits a PackageInstance import marker that gates consuming waves
      # until the Service actually exists on the cluster. The marker
      # carries `kix.dev/service-selector` and `kix.dev/service-ports`
      # annotations so the netpol system can generate proper per-consumer
      # caller-ingress CNPs targeting the operator-managed pods — replacing
      # the blanket `fromEntities = ["cluster"]` pattern.
      #
      # The returned `out.{name, fqdn, port}` values carry the marker's
      # store-path context, so consumers who interpolate them automatically
      # get: (a) a DAG edge for wave ordering, (b) a netpol edge for CNP
      # generation, (c) a DNS dep injection.
      #
      # Usage:
      #   pgService = scope.mkServiceRef {
      #     name = "my-postgres";
      #     selector = { app = "StackGresCluster"; "stackgres.io/cluster-name" = "my-postgres"; };
      #     ports = [{ port = "5432"; protocol = "TCP"; }];
      #     requires = [ self.cluster ];
      #   };
      #   root.out.fqdn = pgService.out.fqdn;
      #
      # `name` may carry Nix string context (e.g. `postgres.out.name`): the
      # filename-strip happens inside k8s.mkResource, and the content-side
      # context flows into the marker's outPath and kix.dev/depends-on
      # annotation automatically. No `unsafeDiscardStringContext` needed;
      # no redundant `requires` re-establishment needed.
      mkServiceRef =
        {
          name,
          selector,
          ports,
          requires ? [ ],
        }:
        let
          markerName = "service-ref-${instanceName}-${name}";

          marker = mkImportMarker {
            inherit markerName;
            importKind = "Service";
            importApiVersion = "v1";
            importName = name;
            extraAnnotations = {
              "kix.dev/service-selector" = builtins.toJSON selector;
              "kix.dev/service-ports" = builtins.toJSON ports;
            };
            extraRequires = requires;
          };

          resourceCtx = builtins.getContext "${marker}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          # Derive the FQDN using the standard <name>.<namespace>.svc pattern.
          fqdn = "${name}.${namespaceName}.svc";
        in
        marker
        // {
          out = {
            name = attachCtx name;
            fqdn = attachCtx fqdn;
            port = attachCtx (toString (builtins.head ports).port);
            # All ports, context-attached, for consumers needing the full list.
            ports = ports;
            # The pod selector that backs this service — exposed so packages
            # can use it directly (e.g. for additional hand-rolled CNPs).
            inherit selector;
          };
        };

      # The scope object — self-referencing via Nix laziness so mkCR can pass
      # the full scope to crd.out.mkCR.
      scopeObj = {
        inherit
          instanceName
          namespaceName
          selectorLabels
          labelStyle
          namespaces
          networkPolicyEnforcer
          ;
        namespace = namespaceResource;

        mkResource = scopeMkResource;

        # --- Edge augmentation ------------------------------------------
        # Stamp passenger resources' store-path context into a value that
        # already carries its own upstream context. Consumers that read
        # the augmented value pick up the original edge AND the
        # passengers in their forward closure — without needing a named
        # chain hop through any of them.
        #
        # Use when your package sits in the middle of an edge between
        # consumer and producer and wants to contribute a resource
        # (typically a readiness-providing Job) to the consumer's closure
        # without re-declaring the producer. Contrast with mkServiceRef,
        # which is for *originating* a service edge.
        #
        # `passengers` is a list of kix resources (things with outPath).
        # `value` is any string (port number, FQDN, name).
        augmentEdge =
          passengers: value:
          let
            extraCtx = builtins.foldl' (
              acc: p: if builtins.isAttrs p && p ? outPath then acc // builtins.getContext "${p}" else acc
            ) { } passengers;
          in
          builtins.appendContext (toString value) extraCtx;

        # Re-stamp every string field of an upstream's `out` attrset
        # with additional passengers. Non-string values pass through
        # untouched. The common case when wrapping a producer's output.
        augmentAllEdges =
          passengers: outAttrs:
          lib.mapAttrs (_: v: if builtins.isString v then scopeObj.augmentEdge passengers v else v) outAttrs;

        # Forward a dep's service edges into this package — the one-call
        # pattern for pass-through packages (e.g. stackgres-database
        # forwarding postgres). Returns a plain attrset combining:
        #
        #   1. `augmentAllEdges passengers dep.out` — the producer's
        #      `out` with every string field's context merged with each
        #      passenger's store-path, so consumers reading the
        #      forwarded values pick up the original edge AND the
        #      passengers in their forward closure.
        #
        #   2. The ServiceRef markers found in `dep.raw` — re-exposed
        #      as typed attributes. When the package author places the
        #      return value in `parts` under a named key (via
        #      `self.pg = scope.forwardEdges ...;`), that key becomes a
        #      folder (no `_type`), `collectTypedAttrs` descends one
        #      level, and the markers auto-register in the consumer's
        #      DI-direct netpol registry.
        #
        # Why both in one call: forwarding context without re-exposing
        # the markers leaves `database.out.host` carrying the right
        # store-path context, but the consumer's `buildWorkloadCnps`
        # registry is built from the consumer's *direct* dep resources
        # (not transitive), so the marker two hops upstream is invisible
        # and no egress/ingress CNP gets emitted. Bundling both sides
        # in `forwardEdges` means the package author's single intent
        # statement — "I'm forwarding this dep's edges with these
        # readiness passengers" — does the context plumbing and the
        # marker re-exposure together.
        #
        # Usage:
        #   build = { self, postgres, ... }: {
        #     bootstrapJob = ...;
        #     pg = scope.forwardEdges postgres [ self.bootstrapJob ];
        #     root.out = {
        #       host = self.pg.fqdn;
        #       port = self.pg.port;
        #     };
        #   };
        #
        # `dep` is a DI-injected dep (instance view); requires `.out`
        # (for edge augmentation) and `.raw` (for marker extraction).
        # Safe from cycles: `dep` is DAG-upstream, fully evaluated by
        # the time the consumer's build function runs.
        forwardEdges =
          dep: passengers:
          let
            augmented = scopeObj.augmentAllEdges passengers (dep.out or { });
            depRaw = dep.raw or { };
            # Extract ServiceRef markers from the dep's raw parts. The
            # `excludeKeys = [ "root" "meta" ]` matches the convention in
            # `_depResourcesForNetpol`: those aren't part of the
            # resource surface.
            typed = builtins.filter (v: (v._type or "") == "k8s-resource") (
              collectTypedAttrs {
                excludeKeys = [
                  "root"
                  "meta"
                ];
              } depRaw
            );
            markers = builtins.filter netpol.isServiceRef typed;
            markerMap = builtins.listToAttrs (
              map (m: {
                inherit (m) name;
                value = m;
              }) markers
            );
          in
          augmented // markerMap;

        # Namespace-bound subscope derived from a dep's _meta.namespaceName.
        # Hides the `scope.forNamespace dep._meta.namespaceName` dance and
        # keeps `_meta` out of the package-author surface.
        forService =
          dep:
          let
            depNs =
              dep._meta.namespaceName
                or (throw "scope.forService: dep has no _meta.namespaceName (external/passthrough?); use scope.forNamespace explicitly");
          in
          scopeObj.forNamespace depNs;

        forNamespace =
          nsName:
          let
            nsRes =
              namespaces.${nsName}
                or (throw "scope.forNamespace: namespace '${nsName}' does not exist in the cluster");
          in
          mkScope {
            inherit
              instanceName
              namespaces
              clusterLabels
              labelStyle
              capabilities
              networkPolicyEnforcer
              networkConfig
              depResourcesForNetpol
              peekedPackageMeta
              skipWorkloadNetpol
              ;
            namespaceName = nsName;
            namespaceResource = nsRes;
          };

        mkClusterResource = scopeMkClusterResource;

        inherit rbac helm;

        mkDeployment = mkWorkload "apps/v1" "Deployment";
        mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkload "apps/v1" "DaemonSet";
        inherit mkJob mkHelmWorkload;

        inherit
          crd
          mkCRD
          mkCRDRef
          mkCR
          mkSecret
          mkSecretRef
          mkServiceRef
          ;
      };
    in
    scopeObj;
}
