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
    else if kind == "CronJob" then
      {
        pattern = "[a-z0-9]([-a-z0-9.]*[a-z0-9])?";
        max = 52;
        desc = "a lowercase DNS-1123 subdomain: letters, digits, '-' or '.', starting and ending alphanumeric";
        maxReason = "the CronJob controller appends an 11-character suffix to the names of the Jobs it creates";
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

  quantity = import ../vocab/quantity.nix { inherit lib; };

  markers = import ../core/markers.nix { inherit lib; };

  # True when a Service spec's `loadBalancerClass` carries string context
  # other than a `kix.untrackedRef` marker, which means it was read from a
  # provider's `out` (tailscale's `out.loadBalancerClass`), so a provider in
  # the build serves the Service. A raw class string, or one wrapped in
  # `kix.untrackedRef`, is false. The check cannot tell a provider's class
  # from a string interpolated from any other resource's `out`; a class
  # built that way also skips the loadBalancer role. An external balancer
  # that publishes a class with context must also open the Service's pods
  # to its own callers, since derived policy then gives the Service no
  # ingress from outside the cluster.
  hasProviderClass =
    spec:
    let
      class = spec.loadBalancerClass or null;
      context = builtins.attrNames (builtins.getContext class);
    in
    builtins.isString class && context != [ ] && !(builtins.any markers.isUntrackedRefPath context);
in
{
  inherit hasProviderClass;

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
            "[kix] warning: [${instanceName}] needs a cluster capability that has not been declared: "
            + "cluster.capabilities.${cap}. Set it to true or false in the cluster definition to match your environment. Kix cannot verify this requirement while it is null."
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
      # are a cluster-operator concern. Packages request storage via DI and
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
          throw "[${instanceName}] ${kind} name '${name}' is ${toString (builtins.stringLength name)} characters; Kubernetes allows at most ${toString rule.max} for this kind${
            lib.optionalString (rule ? maxReason) ", because ${rule.maxReason}"
          }."
        else if malformed then
          throw "[${instanceName}] ${kind} name '${name}' is not valid. It must be ${rule.desc}.${hint}"
        else
          null;

      checkRawPvc =
        args:
        if (args.kind or "") == "PersistentVolumeClaim" && !(builtins.elem "raw-pvc" unsafeGrants) then
          throw (
            "[${instanceName}] PersistentVolumeClaim '${args.name or "unknown"}' is built directly by this package. "
            + "Declare a `storage` dependency and mount it with "
            + "`kix.mount.pvc storage { mountPath = ...; }`, and add a "
            + "`persistent-volume-claim` instance in the cluster definition. Packages that must author "
            + "claims themselves, such as Helm charts with persistence, must declare "
            + "`meta.unsafe = [ \"raw-pvc\" ]`. The scorecard will report this exception."
          )
        else
          null;

      # A Service whose loadBalancerClass comes from a provider in the build
      # is served by that provider, so the cluster's loadBalancer role does
      # not apply to it.
      checkLoadBalancer =
        args:
        let
          specType = args.spec.type or (args.extra.spec.type or null);
          status = roleStatus "loadBalancer";
          serviceDesc = "[${instanceName}] Service '${args.name or "unknown"}' uses type=LoadBalancer";
        in
        if
          (args.kind or "") == "Service"
          && specType == "LoadBalancer"
          && capabilities != { }
          && !(hasProviderClass (args.spec or { }) || hasProviderClass (args.extra.spec or { }))
        then
          if status == "absent" then
            throw (
              serviceDesc
              + " but no load balancer provider is configured (cluster.roles.loadBalancer.binding = \"absent\", "
              + "no provider instance). Use type=ClusterIP or NodePort, add a provider instance, "
              + "or configure cluster.roles.loadBalancer.binding to match your environment."
            )
          else if status == "unknown" then
            builtins.trace (
              "[kix] warning: "
              + serviceDesc
              + " but Kix cannot verify that this cluster has a load balancer provider. Set "
              + "cluster.roles.loadBalancer.binding to match your environment, or add a provider instance."
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
              + "Remove the privileged settings or use a cluster that supports them.";
          }
        else
          null;

      checkDaemonSet =
        kind:
        if kind == "DaemonSet" then
          checkCapability {
            cap = "daemonSets";
            message =
              "[${instanceName}] DaemonSet cannot be deployed: "
              + "cluster.capabilities.daemonSets is false. "
              + "Remove this DaemonSet or use a cluster that supports it.";
          }
        else
          null;

      # A hard placement rule on a multi-replica workload can only ever
      # leave pods Pending on a single-node cluster: one node has exactly
      # one value of every topology key. Refuse when multiNode is declared
      # false, warn when it is unknown (v2_discussions/143 §4). Soft rules
      # and single-replica workloads pass.
      checkSpreadFeasible =
        {
          kind,
          name,
          spec,
        }:
        let
          replicas = spec.replicas or null;
          templateSpec = spec.template.spec or { };
          hardAntiAffinity =
            lst (
              (templateSpec.affinity or { }).podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution or [ ]
            ) != [ ];
          hardSpread = builtins.any (c: (c.whenUnsatisfiable or "") == "DoNotSchedule") (
            lst (templateSpec.topologySpreadConstraints or [ ])
          );
          rule =
            if hardAntiAffinity then
              "required pod anti-affinity"
            else if hardSpread then
              "a DoNotSchedule topology spread constraint"
            else
              null;
          multiNode = capabilities.multiNode or null;
          message =
            "[${instanceName}] ${kind} '${name}' requests ${toString replicas} replicas with ${toString rule}, "
            + "and cluster.capabilities.multiNode is ${if multiNode == null then "unknown" else "false"}. "
            + "This placement rule may prevent replicas from starting on a single node. "
            + "Use preferred anti-affinity or ScheduleAnyway, set replicas to 1, or set multiNode = true if the cluster has multiple nodes.";
        in
        if capabilities == { } || rule == null || !(builtins.isInt replicas) || replicas <= 1 then
          null
        else if multiNode == false then
          throw message
        else if multiNode == null then
          builtins.trace "[kix] warning: ${message}" null
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
              + "Use the resource's out.name or other out helpers so Kix can track the dependency, "
              + "or kix.untrackedRef to opt out explicitly."
            else if refNs != null && refNs != namespaceName && !refReflected then
              throw "[${instanceName}] Cross-namespace ${kind} reference in ${fieldDesc}: "
              + "${kind} \"${plainName}\" is declared in namespace \"${refNs}\" "
              + "but the consuming workload is in namespace \"${namespaceName}\". "
              + "Kubernetes requires this ${kind} to be in the workload's namespace. "
              + "Create or mirror the ${kind} in \"${namespaceName}\" "
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
                    + "cross-namespace validation) or kix.untrackedRef for an externally managed ServiceAccount."
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
          throw "[${instanceName}] ${kind} pod labels do not include all labels in spec.selector.matchLabels: "
          + "selector key(s) ${builtins.concatStringsSep ", " missingKeys} are missing from template labels. "
          + "selector=${fmt selector} templateLabels=${fmt userTemplateLabels}. "
          + "Add the missing selector labels to spec.template.metadata.labels. "
          + "Kubernetes requires every selector label to match the pod template."
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
                    l = quantity.parse res limits.${res};
                    r = quantity.parse res requests.${res};
                  in
                  if l == null || r == null then
                    null
                  else if l < r then
                    throw "[${instanceName}] Container '${c.name}' resources.limits.${res} (${toString limits.${res}}) is lower than resources.requests.${res} (${toString requests.${res}}). "
                    + "Increase the limit or lower the request. Kubernetes requires the limit to be at least the request."
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
