{ lib }:

let
  # A chart can render `volumes: null` or `env: null` (an unset value through
  # toYaml). Every list read below goes through this so a null reads as
  # empty instead of "expected a list but found null" with no resource named.
  lst = v: if v == null then [ ] else v;

  _allowedFieldPaths = [
    "metadata.name"
    "metadata.namespace"
    "metadata.uid"
    "metadata.labels"
    "metadata.annotations"
    "spec.nodeName"
    "spec.serviceAccountName"
    "status.hostIP"
    "status.hostIPs"
    "status.podIP"
    "status.podIPs"
  ];

  _nameRule =
    kind:
    if kind == "Service" then
      {
        pattern = "[a-z]([-a-z0-9]*[a-z0-9])?";
        max = 63;
        desc = "a lowercase RFC 1035 label: start with a letter, then letters, digits or '-', ending alphanumeric";
      }
    else if kind == "Namespace" then
      {
        pattern = "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
        max = 63;
        desc = "a lowercase DNS-1123 label: letters, digits or '-', starting and ending alphanumeric";
      }
    else
      {
        pattern = "[a-z0-9]([-a-z0-9.]*[a-z0-9])?";
        max = 253;
        desc = "a lowercase DNS-1123 subdomain: letters, digits, '-' or '.', starting and ending alphanumeric";
      };

  _parseQuantity =
    resource: q:
    let
      str = builtins.unsafeDiscardStringContext (toString q);
      cpuMilli = builtins.match "([0-9]+)m" str;
      cpuPlainInt = builtins.match "([0-9]+)" str;
      cpuDecimal = builtins.match "([0-9]+)\\.([0-9]+)" str;
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
          fracPadded = builtins.substring 0 3 (frac + "000");
          fracInt = builtins.fromJSON fracPadded;
        in
        whole * 1000 + fracInt
      else if cpuPlainInt != null then
        (builtins.fromJSON (builtins.head cpuPlainInt)) * 1000
      else
        null
    else if memBin != null then
      (builtins.fromJSON (builtins.elemAt memBin 0)) * (binMult (builtins.elemAt memBin 1))
    else if memDec != null then
      (builtins.fromJSON (builtins.elemAt memDec 0)) * (decMult (builtins.elemAt memDec 1))
    else if memPlain != null then
      builtins.fromJSON (builtins.head memPlain)
    else
      null;
in
{
  mkValidators =
    {
      instanceName,
      namespaceName,
      capabilities,
      roleStatus ? (_: "unknown"),
      # Validated unsafe grants from peeked package meta (kix/lib/unsafe.nix).
      unsafeGrants ? [ ],
    }:
    let
      # Three-valued substrate gates (v2_discussions/127 §3): declared-false
      # is an error, unknown (null) is a warning naming the axiom to declare,
      # true passes. The `capabilities == { }` escape keeps standalone scopes
      # (tests, subscope stubs) silent.
      checkCapability =
        {
          cap,
          message,
        }:
        let
          value = capabilities.${cap} or null;
        in
        if capabilities == { } then
          null
        else if value == false then
          throw message
        else if value == null then
          builtins.trace (
            "[kix] warning: [${instanceName}] relies on unknown axiom "
            + "cluster.capabilities.${cap} — declare it in the target (null means unknown, not false)"
          ) null
        else
          null;
      _checkDuplicateNames =
        { includeEnv }:
        templateSpec:
        let
          containers = lst (templateSpec.containers or [ ]);
          initContainers = lst (templateSpec.initContainers or [ ]);
          allContainers = containers ++ initContainers;
          volumes = lst (templateSpec.volumes or [ ]);

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
              envNames = map (e: e.name) (lst (c.env or [ ]));
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
              portNames = map (p: p.name) (builtins.filter (p: p ? name) (lst (c.ports or [ ])));
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
          ++ (if includeEnv then envDups else [ ])
          ++ portDups;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;
    in
    {
      # Structural authoring rule (v2_discussions/128 mechanism 1): raw PVCs
      # are a cluster-operator concern — packages request storage via DI and
      # the `persistent-volume-claim` package is the canonical claim author.
      # Unlike the capability gates above this is target-independent, so it
      # has no `capabilities == { }` escape: the only way out is the explicit
      # `meta.unsafe = [ "raw-pvc" ]` grant, which the scorecard audits.
      # Helm-imported chart resources route through the wrapping package's
      # mkResource, so charts with persistence enabled need the same grant.
      # The Kubernetes OpenAPI schema leaves `metadata.name` unconstrained, so
      # schema validation accepts names that the API server rejects. Check
      # them during evaluation instead. Packages commonly derive names from
      # `scope.instanceName`, making camel-case instance names a frequent
      # source of errors.
      #
      # Three rules, matching apimachinery:
      #   Service    RFC 1035 label, must start with a letter, <= 63
      #   Namespace  DNS-1123 label, no dots, <= 63
      #   otherwise  DNS-1123 subdomain, <= 253
      # RBAC kinds are exempt: the API server validates those as path
      # segments, which is why `prometheus-operator:leader-election` is a
      # legal Role name.
      checkResourceName =
        args:
        let
          kind = args.kind or "";
          name = builtins.unsafeDiscardStringContext (toString (args.name or ""));
          exempt = builtins.elem kind [
            "Role"
            "RoleBinding"
            "ClusterRole"
            "ClusterRoleBinding"
          ];
          rule = _nameRule kind;
          tooLong = builtins.stringLength name > rule.max;
          malformed = builtins.match rule.pattern name == null;
          hint =
            if builtins.match ".*[A-Z].*" name != null then
              " Kubernetes names must be lowercase. Package resources usually derive their names from `scope.instanceName`, so rename the instance in the cluster definition."
            else
              "";
        in
        if kind == "" || name == "" || exempt then
          null
        else if tooLong then
          throw "[${instanceName}] ${kind} name '${name}' is ${toString (builtins.stringLength name)} characters; Kubernetes allows at most ${toString rule.max} for this kind."
        else if malformed then
          throw "[${instanceName}] ${kind} name '${name}' is not valid. It must be ${rule.desc}.${hint} Kix checks this during evaluation because the Kubernetes OpenAPI schema does not constrain `metadata.name`."
        else
          null;

      checkRawPvc =
        args:
        if (args.kind or "") == "PersistentVolumeClaim" && !(builtins.elem "raw-pvc" unsafeGrants) then
          throw (
            "[${instanceName}] PersistentVolumeClaim '${args.name or "unknown"}' is built directly by this package. "
            + "Storage is the cluster operator's concern: declare a `storage` dep and mount it via "
            + "`kix.mount.pvc storage { mountPath = ...; }`, provisioning the claim as a sibling "
            + "`persistent-volume-claim` instance in the cluster definition. Packages that must author "
            + "claims themselves (the canonical storage package, helm charts with persistence) declare "
            + "`meta.unsafe = [ \"raw-pvc\" ]` — the grant is listed by the scorecard unsafe-grant audit."
          )
        else
          null;

      checkLoadBalancer =
        args:
        let
          specType = args.spec.type or (args.extra.spec.type or null);
          status = roleStatus "loadBalancer";
          serviceDesc = "[${instanceName}] Service '${args.name or "unknown"}' uses type=LoadBalancer";
        in
        if (args.kind or "") == "Service" && specType == "LoadBalancer" && capabilities != { } then
          if status == "absent" then
            throw (
              serviceDesc
              + " but the loadBalancer role is vacant (cluster.roles.loadBalancer.binding = \"absent\", "
              + "no managed provider). Use type=ClusterIP or NodePort, add a provider instance, "
              + "or declare the environment binding on the target."
            )
          else if status == "unknown" then
            builtins.trace (
              "[kix] warning: "
              + serviceDesc
              + " but the loadBalancer role is unknown on this target — declare "
              + "cluster.roles.loadBalancer.binding or add a provider"
            ) null
          else
            null
        else
          null;

      checkPrivileged =
        templateSpec:
        let
          containers = lst (templateSpec.containers or [ ]);
          initContainers = lst (templateSpec.initContainers or [ ]);
          allContainers = containers ++ initContainers;
          hasPrivileged = builtins.any (c: (c.securityContext.privileged or false) == true) allContainers;
          hasHostNetwork = templateSpec.hostNetwork or false;
          hasHostPID = templateSpec.hostPID or false;
          volumes = lst (templateSpec.volumes or [ ]);
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
            cap = "privilegedContainers";
            message =
              "[${instanceName}] Workload uses ${reason} "
              + "but cluster.capabilities.privilegedContainers is false. "
              + "This cluster (e.g. GKE Autopilot, OpenShift) restricts privileged workloads.";
          }
        else
          null;

      checkDaemonSet =
        kind:
        if kind == "DaemonSet" then
          checkCapability {
            cap = "daemonSets";
            message =
              "[${instanceName}] DaemonSet cannot be deployed — "
              + "cluster.capabilities.daemonSets is false. "
              + "This cluster (e.g. GKE Autopilot) does not support DaemonSets.";
          }
        else
          null;

      checkNamespacedRefs =
        templateSpec:
        let
          allContainers =
            (lst (templateSpec.containers or [ ])) ++ (lst (templateSpec.initContainers or [ ]));

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

          volumeChecks = builtins.concatMap (
            v:
            (lib.optional (v ? secret) (validate "secret" "volumes[].secret.secretName" v v.secret.secretName))
            ++ (lib.optional (v ? configMap) (
              validate "configMap" "volumes[].configMap.name" v v.configMap.name
            ))
            ++ (lib.optional (v ? persistentVolumeClaim) (
              validate "pvc" "volumes[].persistentVolumeClaim.claimName" v v.persistentVolumeClaim.claimName
            ))
          ) (lst (templateSpec.volumes or [ ]));

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
            ) (lst (c.envFrom or [ ]))
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
            ) (lst (c.env or [ ]))
          ) allContainers;

          pullSecretChecks = map (ps: validate "secret" "imagePullSecrets[].name" ps ps.name) (
            lst (templateSpec.imagePullSecrets or [ ])
          );

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

      checkNamedPorts =
        templateSpec:
        let
          containers = (lst (templateSpec.containers or [ ])) ++ (lst (templateSpec.initContainers or [ ]));

          containerPortNames = c: map (p: p.name) (builtins.filter (p: p ? name) (lst (c.ports or [ ])));

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

      checkContainerResources =
        templateSpec:
        let
          allContainers =
            (lst (templateSpec.containers or [ ])) ++ (lst (templateSpec.initContainers or [ ]));
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

      checkDuplicateNames = _checkDuplicateNames { includeEnv = true; };
      # Charts commonly append user `extraEnv` over defaults; a duplicate
      # env name is valid Kubernetes (the API server warns, last wins), so
      # for chart workloads only container, volume and port names are
      # checked, the three the API server rejects.
      checkDuplicateNamesChart = _checkDuplicateNames { includeEnv = false; };
      checkFieldRefs =
        templateSpec:
        let
          allContainers =
            (lst (templateSpec.containers or [ ])) ++ (lst (templateSpec.initContainers or [ ]));

          isAllowed =
            path:
            builtins.elem path _allowedFieldPaths
            # Bracket expressions for the literal brackets: `\[` is not a
            # valid escape in the extended regex builtins.match uses, and
            # the old form threw "invalid regular expression" on exactly
            # the paths this clause was meant to allow.
            || builtins.match "metadata\\.labels[[]'.*'[]]" path != null
            || builtins.match "metadata\\.annotations[[]'.*'[]]" path != null;

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
            ) (lst (c.env or [ ]));

          allChecks = builtins.concatMap checksPerContainer allContainers;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;
    };
}
