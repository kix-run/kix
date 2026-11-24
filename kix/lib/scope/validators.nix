{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail failFor;
  # Coerce null to an empty list because Helm charts often render unset list
  # fields such as `volumes` or `env` as null.
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

  # Return true when `spec.loadBalancerClass` was produced by
  # `kix.providedLoadBalancerClass`, indicating an in-cluster provider serves it.
  hasProviderClass = spec: markers.isProvidedLoadBalancerClass (spec.loadBalancerClass or null);
in
{
  mkValidators =
    {
      instanceName,
      namespaceName,
      packageId ? null,
      capabilities,
      roleStatus ? (_: "unknown"),
      # Validated unsafe grants from peeked package meta (kix/lib/unsafe.nix).
      unsafeGrants ? [ ],
    }:
    let
      # Fail with `e`, naming this instance.
      failHere = failFor {
        instance = "${namespaceName}/${instanceName}";
        package = packageId;
      };

      # Validate a required cluster capability. Throw when the capability is
      # false, return a warning when it is null, and skip checks when
      # `capabilities` is empty in standalone test scopes. The checks below
      # that can warn return a list of warnings, which the builders attach to
      # the resource as `_warnings` (`scope/builders.nix`).
      checkCapability =
        {
          cap,
          message,
          fix ? null,
          clusterOption ? "cluster.capabilities.${cap}",
        }:
        let
          value = capabilities.${cap} or null;
        in
        if capabilities == { } then
          [ ]
        else if value == false then
          failHere { inherit message fix clusterOption; }
        else if value == null then
          [
            {
              inherit clusterOption;
              message = "This instance requires cluster.capabilities.${cap} = true, which is not set in the cluster definition. Kix built the instance without checking whether the cluster supports this capability.";
              fix = "Set `cluster.capabilities.${cap} = true;` in the cluster definition if the cluster supports it, or `false;` if it does not.";
            }
          ]
        else
          [ ];

      # Check that the cluster provides `metrics.k8s.io` for `subject`. Fail
      # when the metricsApi role is absent, and return a list holding a
      # warning when it is unset.
      metricsApiWarnings =
        subject:
        let
          status = roleStatus "metricsApi";
          desc = "instance '${instanceName}': ${subject} requires the Kubernetes Metrics API (metrics.k8s.io), and";
        in
        if capabilities == { } then
          [ ]
        else if status == "absent" then
          fail {
            message =
              desc
              + " nothing in this cluster provides it (cluster.roles.metricsApi.binding = \"absent\" and no metrics-server instance is declared).";
            fix =
              "Add a metrics-server instance to your cluster definition:"
              + "\n  instances.kube-system.metrics-server.package = packages.experimental.metrics-server;"
              + "\nIf your cluster environment already runs metrics-server, set `cluster.roles.metricsApi.binding = \"exclusive\";` in your cluster definition instead.";
          }
        else if status == "unknown" then
          [
            {
              clusterOption = "cluster.roles.metricsApi.binding";
              message = "${subject} requires the Kubernetes Metrics API (metrics.k8s.io), and cluster.roles.metricsApi.binding is not set. Kix built the instance without checking whether anything in the cluster serves metrics.k8s.io.";
              fix = "Add a `metrics-server` instance to the cluster definition, or set `cluster.roles.metricsApi.binding = \"exclusive\";` if the cluster already runs `metrics-server` outside Kix (or `\"absent\";` if it does not).";
            }
          ]
        else
          [ ];

      # A package returns the result from its top-level `warnings`.
      requireMetricsApi = metricsApiWarnings;

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
                (failHere {
                  message = "Container '${c.name}' has duplicate env var name(s): [${builtins.concatStringsSep ", " d}].";
                })
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
                (failHere {
                  message = "Container '${c.name}' has duplicate named port(s): [${builtins.concatStringsSep ", " d}].";
                })
              ]
          ) allContainers;

          containerNameCheck =
            if containerNameDups != [ ] then
              failHere {
                message = "Pod has duplicate container name(s): [${builtins.concatStringsSep ", " containerNameDups}].";
                fix = "Container names must be unique within a pod.";
              }
            else
              null;

          volumeNameCheck =
            if volumeNameDups != [ ] then
              failHere {
                message = "Pod has duplicate volume name(s): [${builtins.concatStringsSep ", " volumeNameDups}].";
                fix = "Volume names must be unique within a pod. A common cause is multiple mounts auto-derived from resources with the same name.";
              }
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
      inherit requireMetricsApi;

      # Validate `metadata.name` against Kubernetes apimachinery naming rules,
      # since the OpenAPI schema does not constrain `metadata.name`. RBAC kinds
      # are exempt because the API server only forbids path separators in their
      # names.
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
          failHere {
            message = "${kind} name '${name}' is ${toString (builtins.stringLength name)} characters; Kubernetes allows at most ${toString rule.max} for this kind${
              lib.optionalString (rule ? maxReason) ", because ${rule.maxReason}"
            }.";
          }
        else if malformed then
          failHere { message = "${kind} name '${name}' is not valid. It must be ${rule.desc}.${hint}"; }
        else
          null;

      # Reject PersistentVolumeClaims built directly by a package unless the
      # package declares `meta.unsafe = [ "raw-pvc" ]`. Packages should request
      # storage through dependency injection instead.
      checkRawPvc =
        args:
        if (args.kind or "") == "PersistentVolumeClaim" && !(builtins.elem "raw-pvc" unsafeGrants) then
          failHere {
            message = "PersistentVolumeClaim '${args.name or "unknown"}' is built directly by this package.";
            fix =
              "Declare a `storage` dependency and mount it with "
              + "`kix.mount.pvc storage { mountPath = ...; }`, and add a "
              + "`persistent-volume-claim` instance in the cluster definition. Packages that must author "
              + "claims themselves, such as Helm charts with persistence, must declare "
              + "`meta.unsafe = [ \"raw-pvc\" ]`. The scorecard will report this exception.";
          }
        else
          null;

      # Check that the cluster provides a load balancer for `type = LoadBalancer`
      # Services unless an in-cluster provider serves `spec.loadBalancerClass`.
      checkLoadBalancer =
        args:
        let
          specType = args.spec.type or (args.extra.spec.type or null);
          status = roleStatus "loadBalancer";
          serviceDesc = "instance '${instanceName}': Service '${args.name or "unknown"}' sets type = \"LoadBalancer\", and";
        in
        if
          (args.kind or "") == "Service"
          && specType == "LoadBalancer"
          && capabilities != { }
          && !(hasProviderClass (args.spec or { }) || hasProviderClass (args.extra.spec or { }))
        then
          if status == "absent" then
            fail {
              message =
                serviceDesc
                + " this cluster has no load balancer configured (cluster.roles.loadBalancer.binding = \"absent\").";
              fix =
                "If your cluster environment provides a load balancer (such as a cloud controller or MetalLB), add this line to your cluster definition:"
                + "\n  cluster.roles.loadBalancer.binding = \"shadowable\";"
                + "\nIf this cluster has no load balancer, change the Service to `type = \"ClusterIP\";` (or `\"NodePort\"`).";
            }
          else if status == "unknown" then
            [
              {
                object = {
                  kind = "Service";
                  name = builtins.unsafeDiscardStringContext (args.name or "unknown");
                };
                clusterOption = "cluster.roles.loadBalancer.binding";
                message = "Service '${args.name or "unknown"}' sets type = \"LoadBalancer\", and cluster.roles.loadBalancer.binding is not set. Kix built the Service without checking whether the cluster provides a load balancer.";
                fix = "Set `cluster.roles.loadBalancer.binding = \"shadowable\";` in the cluster definition if the cluster provides a load balancer (such as a cloud controller or MetalLB), or `\"absent\";` if it does not.";
              }
            ]
          else
            [ ]
        else
          [ ];

      # Check that `metrics.k8s.io` is available when a HorizontalPodAutoscaler
      # uses CPU defaults or `Resource`/`ContainerResource` metrics.
      checkHorizontalPodAutoscaler =
        args:
        let
          spec = args.spec or (args.extra.spec or { });
          metrics = spec.metrics or [ ];
          readsResourceMetrics =
            (args.apiVersion or "") == "autoscaling/v1"
            || metrics == [ ]
            || metrics == null
            || builtins.any (
              m:
              builtins.elem (m.type or "") [
                "Resource"
                "ContainerResource"
              ]
            ) metrics;
        in
        if (args.kind or "") == "HorizontalPodAutoscaler" && readsResourceMetrics then
          metricsApiWarnings "HorizontalPodAutoscaler '${args.name or "unknown"}'"
        else
          [ ];

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
            message = "Workload uses ${reason} but cluster.capabilities.privilegedContainers is false.";
            fix = "Remove the privileged settings or use a cluster that supports them.";
          }
        else
          [ ];

      checkDaemonSet =
        kind:
        if kind == "DaemonSet" then
          checkCapability {
            cap = "daemonSets";
            message = "DaemonSet cannot be deployed: cluster.capabilities.daemonSets is false.";
            fix = "Remove this DaemonSet or use a cluster that supports it.";
          }
        else
          [ ];

      # Check that multi-replica workloads with required anti-affinity or
      # `DoNotSchedule` spread constraints do not target a single-node cluster,
      # where extra replicas would remain Pending.
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
            lst (templateSpec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution or [ ])
            != [ ];
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
            "${kind} '${name}' requests ${toString replicas} replicas with ${toString rule}, "
            + "and cluster.capabilities.multiNode is ${if multiNode == null then "unknown" else "false"}. "
            + "This placement rule may prevent replicas from starting on a single node.";
          fix = "Use preferred anti-affinity or ScheduleAnyway, set replicas to 1, or set multiNode = true if the cluster has multiple nodes.";
        in
        if capabilities == { } || rule == null || !(builtins.isInt replicas) || replicas <= 1 then
          [ ]
        else if multiNode == false then
          failHere {
            inherit message fix;
            clusterOption = "cluster.capabilities.multiNode";
          }
        else if multiNode == null then
          [
            {
              inherit message fix;
              object = {
                inherit kind;
                name = builtins.unsafeDiscardStringContext name;
              };
              clusterOption = "cluster.capabilities.multiNode";
            }
          ]
        else
          [ ];

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
              fail {
                message = "instance '${instanceName}': ${fieldDesc} uses a plain string \"${plainName}\" for a ${kind} name, so Kix cannot order the workload after the ${kind} or verify that it exists.";
                fix =
                  "Reference the ${kind} resource's .out.name (or use kix.mount.${kind} / .out.keyRef)."
                  + "\nIf \"${plainName}\" is created outside Kix, wrap it in kix.untrackedRef \"${plainName}\".";
              }
            else if refNs != null && refNs != namespaceName && !refReflected then
              fail {
                message = "instance '${instanceName}': ${fieldDesc} references ${kind} \"${plainName}\" in namespace \"${refNs}\", while this workload is in namespace \"${namespaceName}\". Kubernetes requires a mounted or referenced ${kind} to be in the workload's own namespace.";
                fix =
                  "Create the ${kind} in namespace \"${namespaceName}\" (or in a dependency instance in \"${namespaceName}\")."
                  + "\nIf this is a Secret replicated across namespaces by a controller such as Reflector, set reflect = true on its scope.mkSecretRef call.";
              }
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
                  (fail {
                    message = "instance '${instanceName}': spec.template.spec.serviceAccountName uses a plain string \"${plainName}\", so Kix cannot order the workload after the ServiceAccount or verify its namespace.";
                    fix =
                      "Pass the ServiceAccount resource as serviceAccount = self.<part>; in spec.template.spec (or set serviceAccountName = self.<part>.out.name;)."
                      + "\nIf \"${plainName}\" is created outside Kix, set serviceAccountName = kix.untrackedRef \"${plainName}\";.";
                  })
                ]
              else if saNs != null && saNs != namespaceName then
                [
                  (fail {
                    message = "instance '${instanceName}': spec.template.spec.serviceAccount references ServiceAccount \"${plainName}\" in namespace \"${saNs}\", while this workload is in namespace \"${namespaceName}\". Kubernetes requires a pod's ServiceAccount to be in the pod's own namespace.";
                    fix = "Define a ServiceAccount part in this package with `serviceAccount = scope.mkResource { apiVersion = \"v1\"; kind = \"ServiceAccount\"; ... };` and set `serviceAccount = self.serviceAccount;` in spec.template.spec.";
                  })
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
          failHere {
            message =
              "${kind} pod labels do not include all labels in spec.selector.matchLabels: "
              + "selector key(s) ${builtins.concatStringsSep ", " missingKeys} are missing from template labels. "
              + "selector=${fmt selector} templateLabels=${fmt userTemplateLabels}.";
            fix = "Add the missing selector labels to spec.template.metadata.labels. Kubernetes requires every selector label to match the pod template.";
          }
        else if mismatchedKeys != [ ] then
          failHere {
            message =
              "${kind} spec.selector.matchLabels value mismatch on key(s) "
              + "${builtins.concatStringsSep ", " mismatchedKeys}: "
              + "selector=${fmt selector} templateLabels=${fmt userTemplateLabels}.";
          }
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
                  (failHere {
                    message =
                      "Container '${c.name}' ${p.name} references named port "
                      + "\"${portName}\" which is not declared by the container. "
                      + "Declared named ports: [${builtins.concatStringsSep ", " names}].";
                    fix = "Add `ports = [ (kix.port \"${portName}\" <N>) ]` or use a numeric port.";
                  })
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
                    # Check whether `quantity.parse` can represent the value as
                    # a 64-bit integer before calling it, so out-of-range values
                    # fail with the container and field name.
                    problem =
                      field: values:
                      let
                        reason = quantity.problem res values.${res};
                      in
                      if reason == null then
                        null
                      else
                        "Container '${c.name}' resources.${field}.${res} (${toString values.${res}}) cannot be computed exactly: ${reason}. Kix computes quantities as 64-bit integers.";
                    limitProblem = problem "limits" limits;
                    requestProblem = problem "requests" requests;
                    l = quantity.parse res limits.${res};
                    r = quantity.parse res requests.${res};
                  in
                  if limitProblem != null then
                    failHere { message = limitProblem; }
                  else if requestProblem != null then
                    failHere { message = requestProblem; }
                  else if l == null || r == null then
                    null
                  else if l < r then
                    failHere {
                      message = "Container '${c.name}' resources.limits.${res} (${toString limits.${res}}) is lower than resources.requests.${res} (${toString requests.${res}}).";
                      fix = "Increase the limit or lower the request. Kubernetes requires the limit to be at least the request.";
                    }
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
      # Check container, volume, and port names for chart workloads while allowing
      # duplicate env var names, which charts often produce when appending user
      # overrides and which the API server accepts with last-wins semantics.
      checkDuplicateNamesChart = _checkDuplicateNames { includeEnv = false; };
      checkFieldRefs =
        templateSpec:
        let
          allContainers =
            (lst (templateSpec.containers or [ ])) ++ (lst (templateSpec.initContainers or [ ]));

          isAllowed =
            path:
            builtins.elem path _allowedFieldPaths
            # Match literal `[` and `]` with character classes because POSIX
            # extended regular expressions in `builtins.match` do not support
            # `\[` escapes.
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
                    (failHere {
                      message = "env '${e.name}' in container '${c.name}' uses unsupported fieldRef.fieldPath \"${fp}\".";
                      fix =
                        "Use one of: ${builtins.concatStringsSep ", " _allowedFieldPaths}, "
                        + "metadata.labels['<key>'], metadata.annotations['<key>'].";
                    })
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
