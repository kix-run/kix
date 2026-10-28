{ lib }:

let
  markers = import ../core/markers.nix { inherit lib; };

  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  normalize = import ../core/normalize.nix { inherit lib; };

  quantity = import ./quantity.nix { inherit lib; };

  gatewayContract = import ./gateway.nix { inherit lib; };

  # Return true when `name` is a valid Kubernetes ResourceRequirements key.
  isResourceName =
    name:
    builtins.elem name [
      "cpu"
      "memory"
      "ephemeral-storage"
    ]
    || builtins.match "hugepages-.+" name != null
    || lib.hasInfix "/" name;

  # Strip null leaves and empty sections from a `kix.options.resources` value.
  # Validate undeclared resource names here because a submodule `freeformType`
  # does not run its own `check`.
  cleanResources =
    value:
    let
      dropNulls = lib.filterAttrs (_: v: v != null);
      side =
        sideName:
        let
          kept = dropNulls value.${sideName};
          bad = builtins.filter (n: !(isResourceName n)) (builtins.attrNames kept);
        in
        if bad != [ ] then
          throw "kix.options.resources: ${
            lib.concatMapStringsSep ", " (n: "${sideName}.${n}") bad
          } is not a resource name. Use cpu, memory or ephemeral-storage, hugepages-<size>, or an extended resource whose name contains \"/\" (nvidia.com/gpu)."
        else
          kept;
      requests = side "requests";
      limits = side "limits";
    in
    lib.optionalAttrs (requests != { }) { inherit requests; }
    // lib.optionalAttrs (limits != { }) { inherit limits; }
    // lib.optionalAttrs (value.claims != null) { claims = map dropNulls value.claims; };

  resourceNamespace =
    resource:
    let
      ns = resource.namespace or null;
    in
    if ns == null then
      null
    else if (ns._type or "") == "k8s-cluster-scoped" then
      null
    else
      ns.name or null;

  stampSourceNamespace =
    sourceKind: resource: sourceAttrs:
    let
      ns = resourceNamespace resource;
    in
    sourceAttrs
    // lib.optionalAttrs (ns != null) {
      _kix = {
        namespace = ns;
        source = sourceKind;
      };
    };

  resolveServicePort =
    caller: port: svc:
    if port != null then
      port
    else if svc ? out.port then
      builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
    else
      throw "${caller}: service '${svc.name or "unknown"}' has no out.port. Specify port explicitly";

  # Compute the public route record `{ via; host; rawHost; scheme; url; urlOrNull; }`
  # that `kix.expose` publishes for an instance.
  #
  # `via` is "gateway", "ingress", or null when no route is configured.
  # `scheme` is null when the gateway does not publish `out.listeners` (such as
  # a `kix.mkImport`). `url` throws when no route or scheme is available, while
  # `urlOrNull` returns null for packages that can run without a public URL.
  # Reading only `config`, `clusterConfig`, `scope`, and exposure dependencies
  # avoids forcing `self` so any part can read `exposure`.
  exposureOf =
    {
      name,
      config,
      clusterConfig,
      scope,
      gateway,
      ingressNginx,
      clusterIssuer,
      deriveHost ? true,
    }:
    let
      publicDomain = clusterConfig.cluster.domain or null;
      configHost = (config.ingress or { }).host or null;
      candidateHost =
        if configHost != null then
          configHost
        else if deriveHost && publicDomain != null then
          "${name}.${publicDomain}"
        else
          null;

      # Ignore unrelated instances named `gateway` (such as an OpenTelemetry
      # Collector) that do not claim the gateway contract.
      hasGateway = gateway != null && gatewayContract.claims gateway;
      # Validate the gateway contract when `listener` is forced by the
      # HTTPRoute.
      checkedGateway =
        if hasGateway then
          gatewayContract.require "kix.expose (${scope.namespaceName}/${name})" gateway
        else
          null;
      hasIngress = ingressNginx != null;
      mode =
        if hasGateway then
          if hasIngress then
            throw "kix.expose (${name}): both 'gateway' and 'ingressNginx' are present. Wire exactly one via deps in the cluster definition."
          else
            "gateway"
        else if hasIngress then
          "ingress"
        else
          null;

      via = if mode != null && candidateHost != null then mode else null;
      rawHost = if via != null then candidateHost else null;
      host = if rawHost == null then null else builtins.unsafeDiscardStringContext rawHost;

      listener =
        if via == "gateway" then
          gatewayListener {
            inherit
              name
              host
              scope
              ;
            gateway = checkedGateway;
          }
        else
          null;

      scheme =
        if via == "ingress" then
          if clusterIssuer != null then "https" else "http"
        else if listener != null then
          listener.scheme
        else
          null;

      defaultPort = if scheme == "https" then 443 else 80;
      portSuffix = lib.optionalString (
        listener != null && listener.port != defaultPort
      ) ":${toString listener.port}";

      urlOrNull = if scheme == null then null else "${scheme}://${host}${portSuffix}";
      gwRef = checkedGateway.out.gatewayRef;
      missing =
        if mode == null then
          "nothing routes to it: wire a gateway or ingressNginx dependency"
        else if candidateHost == null then
          if deriveHost then
            "its route has no host: set ingress.host on the instance or cluster.domain"
          else
            "its route has no host: set ingress.host on the instance"
        else
          "Gateway ${gwRef.namespace}/${gwRef.name} publishes no out.listeners, so Kix cannot tell which listener the HTTPRoute attaches to, or its scheme and port: use a gateway instance that publishes out.listeners";
    in
    {
      inherit
        via
        host
        rawHost
        scheme
        urlOrNull
        ;
      url =
        if urlOrNull != null then
          urlOrNull
        else
          throw "kix.expose (${scope.namespaceName}/${name}): the package reads the instance's public URL (exposure.url), but ${missing}. If the package has an option for its URL, set that instead.";
    };

  # Select the Gateway listener that an HTTPRoute for `host` in `scope` attaches
  # to, returning `{ scheme; port; }` or null when the gateway does not publish
  # `out.listeners`.
  #
  # Matches HTTP and HTTPS listeners whose `hostname` is unset, exact, or a
  # matching `*.` wildcard, and whose `allowedRoutes.namespaces.from` admits
  # the route namespace (`Same` when unset). Listeners using `Selector` cannot
  # be verified statically and are ranked below verified listeners with a
  # warning. Throws when no listener accepts the route.
  gatewayListener =
    {
      name,
      host,
      scope,
      gateway,
    }:
    let
      gwRef = gateway.out.gatewayRef;
      gwLabel = "Gateway ${gwRef.namespace}/${gwRef.name}";
      routeNs = scope.namespaceName;
      listeners = gateway.out.listeners or null;

      hostnameOf = l: l.hostname or null;
      fromOf = l: l.allowedRoutes.namespaces.from or null;

      hostMatches =
        l:
        let
          h = hostnameOf l;
        in
        h == null || h == host || (lib.hasPrefix "*." h && lib.hasSuffix (lib.removePrefix "*" h) host);

      # Return "verified", "unverified" (for `Selector`), or a rejection reason.
      verdict =
        l:
        let
          from = fromOf l;
        in
        if
          !(builtins.elem l.protocol [
            "HTTP"
            "HTTPS"
          ])
        then
          "protocol is ${l.protocol}"
        else if !(hostMatches l) then
          "hostname \"${hostnameOf l}\" does not match"
        else if from == "All" then
          "verified"
        else if from == "Selector" then
          "unverified"
        else if gwRef.namespace == routeNs then
          "verified"
        else
          "allowedRoutes.namespaces.from is ${
            if from == null then "unset (Same)" else from
          } and the Gateway is in \"${gwRef.namespace}\"";

      judged = lib.imap0 (i: l: {
        inherit i l;
        v = verdict l;
        scheme = if l.protocol == "HTTPS" then "https" else "http";
      }) listeners;

      candidates = builtins.filter (j: j.v == "verified" || j.v == "unverified") judged;

      rank = j: [
        (if j.v == "verified" then 0 else 1)
        (if j.scheme == "https" then 0 else 1)
        (if j.l.port == (if j.scheme == "https" then 443 else 80) then 0 else 1)
        j.i
      ];
      chosen = builtins.head (builtins.sort (a: b: rank a < rank b) candidates);

      checked = builtins.concatStringsSep ", " (map (j: "${j.l.name} (${j.v})") judged);
    in
    if listeners == null then
      null
    else if candidates == [ ] then
      throw "kix.expose (${name}): ${gwLabel} has no HTTP or HTTPS listener that accepts host \"${host}\" from namespace \"${routeNs}\", so the HTTPRoute would not attach. Checked: ${
        if judged == [ ] then "no listeners" else checked
      }. Add a listener for this host with allowedRoutes.namespaces.from = \"All\" to the gateway instance, or set ingress.host to a name one of its listeners accepts."
    else
      (
        if chosen.v == "unverified" then
          lib.warn "kix.expose (${name}): ${gwLabel} listener \"${chosen.l.name}\" admits routes by namespace selector, which Kix does not check. The URL assumes namespace \"${routeNs}\" matches it."
        else
          lib.id
      )
        {
          inherit (chosen) scheme;
          inherit (chosen.l) port;
        };

  # Build the PrometheusRule part shared by `alerts` and `monitor`. Kept
  # separate because `monitor` takes an `alerts` argument that would shadow the
  # public `alerts` helper.
  alertsPart =
    {
      alerts,
      name,
      extraLabels,
      rulesPart,
    }:
    {
      config,
      scope,
      prometheus ? null,
      ...
    }:
    let
      ruleName = if name != null then name else scope.instanceName;
      metricsEnabled = ((config.metrics or { }).enabled or true) && prometheus != null;
      alertRules = lib.mapAttrsToList (
        alertName: alertDef:
        {
          alert = alertName;
          expr = alertDef.expr;
          labels = {
            severity = alertDef.severity or "warning";
          }
          // (alertDef.labels or { });
          annotations =
            { }
            // lib.optionalAttrs (alertDef ? description) {
              description = alertDef.description;
            }
            // lib.optionalAttrs (alertDef ? summary) {
              summary = alertDef.summary;
            }
            // lib.optionalAttrs (alertDef ? runbook_url) {
              runbook_url = alertDef.runbook_url;
            }
            // (alertDef.annotations or { });
        }
        // lib.optionalAttrs (alertDef ? "for") {
          "for" = alertDef."for";
        }
        // lib.optionalAttrs (alertDef ? keep_firing_for) {
          inherit (alertDef) keep_firing_for;
        }
      ) alerts;
    in
    {
      ${rulesPart} =
        if metricsEnabled && alerts != { } then
          prometheus.out.mkPrometheusRule scope {
            name = "${ruleName}-alerts";
            labels = extraLabels;
            spec = {
              groups = [
                {
                  name = "${ruleName}-alerts";
                  rules = alertRules;
                }
              ];
            };
          }
        else
          null;
    };
in

rec {

  # Expose annotation keys from `core/annotations.nix`.
  keys = kixKeys;

  # Expose canonical annotation values from `core/annotations.nix`.
  keyValues = kixAnnotations.values;

  # Expose endpoint fact constructors (`core/facts.nix`).
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect structural;
  };

  # Format and inspect container image references (`{ repository; tag; digest?; }`).
  # These helpers do not validate digest syntax or query a registry. See
  # `pins.nix` for pin file loading and validation.
  image =
    let
      needField =
        image: field:
        let
          v = image.${field} or null;
        in
        if v == null || v == "" then
          throw "kix.image.ref: image reference has no '${field}'. An image needs at least { repository, tag }, and got: ${builtins.toJSON image}"
        else
          v;
    in
    {
      # Render `repository:tag` with `@digest` appended when `digest` is non-null.
      # Discard string context so Nix-built image tags do not add build-time
      # store dependencies to rendered manifests while still allowing
      # `kix-image-sources.json` to classify the option value as `nix_built`.
      ref =
        image:
        builtins.unsafeDiscardStringContext (
          "${needField image "repository"}:${needField image "tag"}"
          + lib.optionalString (image.digest or null != null) "@${image.digest}"
        );

      # Return true when `image.digest` is present and non-null.
      isPinned = image: (image.digest or null) != null;
    };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  # Convert an attrset of environment variables into a Kubernetes `env` list,
  # dropping null entries. Each value may be a string or a `valueFrom` attrset
  # (such as `secret.out.keyRef "password"`), which preserves its dependency
  # context so the workload is ordered after the referenced resource.
  mkEnvVars =
    attrs:
    lib.mapAttrsToList (
      name: value:
      if !builtins.isAttrs value || value ? outPath || value ? __toString then
        { inherit name value; }
      else if value ? valueFrom then
        value // { inherit name; }
      else
        throw "kix.mkEnvVars: ${name} is an attrset with no `valueFrom`, which would render as an env var whose value is an object. Pass a string, or a source such as `secret.out.keyRef \"key\"`. Got: ${builtins.toJSON (builtins.attrNames value)}"
    ) (lib.filterAttrs (_: v: v != null) attrs);

  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  # Merge `overrides` into `base` with `lib.recursiveUpdate`, throwing if
  # `overrides` touches any attribute path in `locked` or replaces a parent of
  # a locked path with a non-attrset value.
  mergeGuarded =
    {
      who,
      locked,
      what ? "extraSpec",
    }:
    base: overrides:
    let
      # Return the shortest proper prefix of `path` that `overrides` sets to a
      # non-attrset, or null when none exists.
      replacingAncestor =
        path:
        lib.findFirst (
          prefix:
          lib.hasAttrByPath prefix overrides && !builtins.isAttrs (lib.getAttrFromPath prefix overrides)
        ) null (map (n: lib.take n path) (lib.range 1 (builtins.length path - 1)));

      describe =
        path:
        let
          shown = lib.concatStringsSep "." path;
          ancestor = replacingAncestor path;
          value = lib.getAttrFromPath ancestor overrides;
        in
        if lib.hasAttrByPath path overrides then
          shown
        else if ancestor == null then
          null
        else
          "${shown} (replaced by `${lib.concatStringsSep "." ancestor} = ${
            if value == null then "null" else "<${builtins.typeOf value}>"
          }`)";

      touched = builtins.filter (d: d != null) (map describe locked);
    in
    if touched != [ ] then
      throw "${who}: ${what} overrides ${lib.concatStringsSep ", " touched}, which the package sets for correctness. Use the option that owns it."
    else
      lib.recursiveUpdate base overrides;

  # Validate Kubernetes resource quantities (`vocab/quantity.nix`).
  types.quantity = quantity.type;

  # Parse a Kubernetes quantity `q` into millicores when `resource` is "cpu"
  # and into bytes otherwise, rounded down, or return null when `q` is not a
  # valid quantity.
  parseQuantity = quantity.parse;

  # Merge package `defaults`, user `env` (`kix.options.env`), and package-owned
  # variables into an attrset for `kix.mkEnvVars`.
  #
  # Each entry in `owned` has `{ vars ? { }; names ? [ ]; from; fix; }`. `vars`
  # are added to the result, while `names` reserves variables delivered via
  # `envFrom`. Throws if `env` defines any key in `vars` or `names` (even as
  # null).
  mergeEnv =
    {
      who,
      owned ? [ ],
      defaults ? { },
    }:
    env:
    let
      hits =
        group:
        builtins.filter (n: env ? ${n}) (builtins.attrNames (group.vars or { }) ++ group.names or [ ]);
      lines = builtins.concatMap (
        group:
        let
          h = hits group;
        in
        lib.optional (h != [ ])
          "${who}: env sets ${lib.concatStringsSep ", " h}, which ${
            if builtins.length h == 1 then "comes" else "come"
          } from ${group.from}. ${group.fix}"
      ) owned;
    in
    if lines != [ ] then
      throw (lib.concatStringsSep "\n" lines)
    else
      defaults // env // lib.foldl' (acc: group: acc // group.vars or { }) { } owned;

  # Validate that `args` does not set any CLI flag in `owned`, and return
  # `args`.
  #
  # `owned` maps each reserved flag to an explanation and remedy. Matches exact
  # flags, `--flag=value`, and short flags with attached values (such as
  # `-c/etc/x`, which also matches multi-character single-dash Go flags like
  # `-vmodule=x` when `-v` is owned).
  guardArgs =
    {
      who,
      option ? "extraArgs",
      owned,
    }:
    args:
    let
      isShortFlag = flag: builtins.match "-[^-]" flag != null;
      flagOf =
        arg:
        lib.findFirst (
          flag: arg == flag || lib.hasPrefix "${flag}=" arg || (isShortFlag flag && lib.hasPrefix flag arg)
        ) null (builtins.attrNames owned);
      lines = builtins.concatMap (
        arg:
        let
          flag = flagOf arg;
        in
        lib.optional (
          flag != null
        ) "${who}: ${option} sets \"${arg}\", which the package owns: ${owned.${flag}}"
      ) args;
    in
    if lines != [ ] then throw (lib.concatStringsSep "\n" lines) else args;

  # Validate that a secret dependency `dep` declares all required `keys` (and
  # at least one key group in `anyOf` when set) in `dep.out.keys`, then return
  # `dep`. Read `keyRef` through the returned value so validation runs first.
  checkSecretKeys =
    {
      who,
      arg,
      dep,
      keys ? [ ],
      anyOf ? null,
    }:
    let
      declared = if dep.out.keys or null == null then [ ] else dep.out.keys;
      missingOf = names: builtins.filter (k: !(builtins.elem k declared)) names;
      missingKeys = missingOf keys;
      groupMet = anyOf == null || builtins.any (group: missingOf group == [ ]) anyOf;
      showGroup = group: "[${lib.concatStringsSep ", " group}]";
      wanted =
        lib.optional (missingKeys != [ ]) (lib.concatStringsSep ", " missingKeys)
        ++ lib.optional (!groupMet) "one of ${lib.concatMapStringsSep " or " showGroup anyOf}";
      declaredText = if declared == [ ] then "no keys" else lib.concatStringsSep ", " declared;
    in
    if dep == null || wanted == [ ] then
      dep
    else
      throw "${who}: deps.${arg} resolved to secret \"${dep.out.name}\", which declares ${declaredText}; this package reads ${lib.concatStringsSep " and " wanted}. Add them to that instance's keys (a SOPS secret lists them in keys), or wire another secret with deps.${arg} = ref.<ns>.<instance>.";

  # Build a network policy for operand pods created at runtime by an operator,
  # or return null when no policy is needed.
  #
  # Drops `ingress`/`ingressDeny` or `egress`/`egressDeny` sections for
  # directions the cluster does not enforce (`scope.networkPolicyEnforced`),
  # because including an unenforced direction would isolate the pods in that
  # direction. Returns null when `scope` has no enforcer or all sections were
  # dropped.
  operandPolicy =
    {
      scope,
      name,
      spec,
    }:
    let
      enforced = scope.networkPolicyEnforced;
      sections = {
        ingress = [
          "ingress"
          "ingressDeny"
        ];
        egress = [
          "egress"
          "egressDeny"
        ];
      };
      unenforced =
        lib.optionals (!enforced.ingress) sections.ingress
        ++ lib.optionals (!enforced.egress) sections.egress;
      enforcedSpec = removeAttrs spec unenforced;
      hasSection = s: builtins.any (k: s ? ${k}) (sections.ingress ++ sections.egress);
    in
    if scope.networkPolicyEnforcer == null || (hasSection spec && !hasSection enforcedSpec) then
      null
    else
      scope.networkPolicyEnforcer.netpol.mkPolicy {
        mkResource = scope.mkResource;
        extraArgs = {
          inherit name;
          spec = enforcedSpec;
          labels = {
            ${kixKeys.derived} = "true";
            ${kixKeys.policyType} = "operator-managed-workload";
          };
          extraDeps = [ ];
        };
      };

  service = {
    extractPorts =
      workload:
      let
        containers = workload.rawManifest.spec.template.spec.containers or [ ];
        allPorts = builtins.concatMap (c: c.ports or [ ]) containers;
      in
      map (
        cp:
        {
          port = cp.containerPort;
          protocol = cp.protocol or "TCP";
        }
        // lib.optionalAttrs (cp ? name) {
          name = cp.name;
        }
      ) allPorts;

    fromWorkload =
      {
        name,
        type ? "ClusterIP",
        ports ? null,
        ...
      }@cfg:
      workload:
      let
        finalPorts = if ports != null then ports else service.extractPorts workload;
        firstPort = if finalPorts != [ ] then toString (builtins.head finalPorts).port else null;
        autoOutputs = lib.optionalAttrs (firstPort != null) { port = firstPort; };
        passthrough = removeAttrs cfg [
          "name"
          "type"
          "ports"
        ];

        workloadPortNames = lib.unique (
          builtins.concatMap (c: builtins.catAttrs "name" (c.ports or [ ])) (
            workload.rawManifest.spec.template.spec.containers or [ ]
          )
        );
        workloadPortNumbers = builtins.listToAttrs (
          builtins.concatMap (
            c:
            map (cp: {
              name = cp.name;
              value = cp.containerPort;
            }) (builtins.filter (cp: cp ? name) (c.ports or [ ]))
          ) (workload.rawManifest.spec.template.spec.containers or [ ])
        );
        badTargets = builtins.filter (
          p:
          (p ? targetPort)
          && builtins.isString p.targetPort
          && !(builtins.elem p.targetPort workloadPortNames)
        ) finalPorts;
        # Resolve named `targetPort` values to numbers while the workload is
        # available, because Cilium 1.19 drops egress traffic when derived
        # network-policy rules use named ports.
        resolvedPorts = map (
          p:
          if (p ? targetPort) && builtins.isString p.targetPort then
            p // { targetPort = workloadPortNumbers.${p.targetPort}; }
          else
            p
        ) finalPorts;
        _portCheck =
          if ports != null && badTargets != [ ] then
            throw "service.fromWorkload '${name}': targetPort(s) [${
              builtins.concatStringsSep ", " (map (p: "\"${p.targetPort}\"") badTargets)
            }] do not match any named container port on the workload. "
            + "Declared container ports: [${builtins.concatStringsSep ", " workloadPortNames}]."
          else
            null;
      in
      # Merge passthrough fields into the generated Service so additions such
      # as `spec.clusterIP` preserve its selector and ports.
      builtins.seq _portCheck (
        lib.recursiveUpdate {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          spec = {
            inherit type;
            selector = workload.out.selector;
            ports = resolvedPorts;
          };
          outputs = autoOutputs // (cfg.outputs or { });
        } (removeAttrs passthrough [ "outputs" ])
      );
  };

  ingress = {
    fromService =
      {
        name,
        host,
        path ? "/",
        pathType ? "Prefix",
        port ? null,
        className ? null,
        tls ? [ ],
        ...
      }@cfg:
      svc:
      let
        servicePort = resolveServicePort "ingress.fromService" port svc;
        passthrough = removeAttrs cfg [
          "name"
          "host"
          "path"
          "pathType"
          "port"
          "className"
          "tls"
        ];
      in
      {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        inherit name;
        spec = {
          rules = [
            {
              inherit host;
              http.paths = [
                {
                  inherit path pathType;
                  backend.service = {
                    name = svc.out.name;
                    port.number = servicePort;
                  };
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs (className != null) { ingressClassName = className; }
        // lib.optionalAttrs (tls != [ ]) { inherit tls; };
      }
      // passthrough;
  };

  httpRoute = {
    fromService =
      {
        name,
        host,
        parentRef,
        path ? "/",
        pathType ? "PathPrefix",
        port ? null,
        # Per-rule Gateway API HTTPRoute timeouts, such as
        # `{ request = "0s"; backendRequest = "0s"; }` to disable timeouts for
        # streaming backends. Null omits the field.
        timeouts ? null,
        ...
      }@cfg:
      svc:
      let
        servicePort = resolveServicePort "httpRoute.fromService" port svc;
        passthrough = removeAttrs cfg [
          "name"
          "host"
          "parentRef"
          "path"
          "pathType"
          "port"
          "timeouts"
        ];
      in
      {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        inherit name;
        spec = {
          parentRefs = [
            (
              {
                name = parentRef.name;
              }
              // lib.optionalAttrs (parentRef ? namespace) { namespace = parentRef.namespace; }
            )
          ];
          hostnames = [ host ];
          rules = [
            (
              {
                matches = [
                  {
                    path = {
                      type = pathType;
                      value = path;
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = svc.out.name;
                    port = servicePort;
                  }
                ];
              }
              // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
            )
          ];
        };
      }
      // passthrough;
  };

  # Map an Ingress `pathType` to a Gateway API path match type so `paths`
  # entries work in both Ingress and Gateway modes.
  gatewayPathType =
    caller: t:
    if t == "Prefix" || t == "PathPrefix" then
      "PathPrefix"
    else if t == "Exact" then
      "Exact"
    else
      throw "${caller}: pathType \"${toString t}\" has no Gateway API equivalent (use Prefix or Exact)";

  # Build an HTTPRoute with one rule per entry in `paths`.
  httpRoute.fromPaths =
    {
      name,
      host,
      parentRef,
      timeouts ? null,
      # List of `{ path; pathType ? "Prefix"; svc; port ? null; }`.
      paths,
    }:
    {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      inherit name;
      spec = {
        parentRefs = [
          (
            {
              name = parentRef.name;
            }
            // lib.optionalAttrs (parentRef ? namespace) { namespace = parentRef.namespace; }
          )
        ];
        hostnames = [ host ];
        rules = map (
          p:
          {
            matches = [
              {
                path = {
                  type = gatewayPathType "httpRoute.fromPaths (${name})" (p.pathType or "Prefix");
                  value = p.path;
                };
              }
            ];
            backendRefs = [
              {
                name = p.svc.out.name;
                port = resolveServicePort "httpRoute.fromPaths (${name})" (p.port or null) p.svc;
              }
            ];
          }
          // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
        ) paths;
      };
    };

  inherit (normalize) keep;

  mount = {
    pvc =
      resource:
      {
        mountPath,
        name ? null,
        readOnly ? false,
        subPath ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "pvc" resource {
            persistentVolumeClaim.claimName = resource.out.name;
          };
        };

    configMap =
      resource:
      {
        mountPath,
        name ? null,
        # ConfigMap volumes are always read-only. Setting `readOnly = true`
        # also records `readOnly` on the container's `volumeMounts` entry.
        readOnly ? false,
        subPath ? null,
        items ? null,
        defaultMode ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "configMap" resource {
            configMap = {
              name = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          };
        };

    secret =
      resource:
      {
        mountPath,
        name ? null,
        subPath ? null,
        items ? null,
        defaultMode ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "secret" resource {
            secret = {
              secretName = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          };
        };

    emptyDir =
      {
        mountPath,
        name,
        medium ? null,
        sizeLimit ? null,
        subPath ? null,
      }:
      {
        _type = "kix-mount";
        inherit name mountPath;
        ${if subPath != null then "subPath" else null} = subPath;
        source.emptyDir =
          { }
          // lib.optionalAttrs (medium != null) { inherit medium; }
          // lib.optionalAttrs (sizeLimit != null) { inherit sizeLimit; };
      };

    hostPath =
      {
        mountPath,
        name,
        hostPath,
        type ? "DirectoryOrCreate",
        readOnly ? false,
        subPath ? null,
      }:
      {
        _type = "kix-mount";
        inherit name mountPath readOnly;
        ${if subPath != null then "subPath" else null} = subPath;
        source.hostPath = {
          path = hostPath;
          inherit type;
        };
      };
  };

  _injectMounts =
    targetName: mounts: attrs:
    let
      validMounts = builtins.filter (m: m != null) mounts;
      volumes = map (m: { inherit (m) name; } // m.source) validMounts;

      existingVolumes = attrs.spec.template.spec.volumes or [ ];
      existingNames = builtins.catAttrs "name" existingVolumes;
      newNames = builtins.catAttrs "name" volumes;
      allNames = existingNames ++ newNames;
      seen = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } allNames;
      dupes = lib.filter (n: seen.${n} > 1) (lib.attrNames seen);
      _dupeCheck =
        if dupes != [ ] then
          throw "kix.withMounts: duplicate volume name(s) [${builtins.concatStringsSep ", " dupes}]. "
          + "Pass `name = \"...\";` to kix.mount.* to disambiguate, or drop the duplicate."
        else
          null;
      volumeMounts = map (
        m:
        {
          inherit (m) name mountPath;
        }
        // lib.optionalAttrs (m ? subPath && m.subPath != null) { inherit (m) subPath; }
        // lib.optionalAttrs (m.readOnly or false) { readOnly = true; }
      ) validMounts;

      templateSpec = attrs.spec.template.spec or { };
      containers = templateSpec.containers or [ ];

      injectInto = c: c // { volumeMounts = (c.volumeMounts or [ ]) ++ volumeMounts; };

      injectedContainers =
        if targetName != null then
          map (c: if c.name == targetName then injectInto c else c) containers
        else if builtins.length containers == 1 then
          [ (injectInto (builtins.head containers)) ]
        else if containers == [ ] then
          containers
        else
          throw "withMounts: the workload has multiple containers. Use withMountsOn to select the container to mount into";
    in
    builtins.seq _dupeCheck attrs
    // {
      spec = attrs.spec // {
        template = attrs.spec.template // {
          spec = templateSpec // {
            volumes = (templateSpec.volumes or [ ]) ++ volumes;
            containers = injectedContainers;
          };
        };
      };
    };

  withMounts = _injectMounts null;

  withMountsOn = containerName: _injectMounts containerName;

  untrackedRef = markers.mkUntrackedRef;

  providedLoadBalancerClass = markers.mkProvidedLoadBalancerClass;

  options = {
    # Build a container image submodule option (`repository`, `tag`, `digest`,
    # `pullPolicy`, and pin metadata).
    #
    # When an instance overrides only some fields, the remaining fields keep
    # the package defaults. The default `digest` is kept only while `config.tag`
    # matches the package's `tag`.
    #
    # Set `tagText` when a package derives `config.image.tag` from another
    # option so generated docs show the expression while `digest` still compares
    # against `tag`. Leave `repository` or `tag` null in framework packages that
    # have no default image of their own.
    image =
      {
        repository ? null,
        tag ? null,
        digest ? null,
        pullPolicy ? "IfNotPresent",
        tagText ? null,
        description ? "Container image for this instance. Set it from a pin file (`kix.pins`) so the deployed reference is committed and resolved.",
      }:
      assert lib.assertMsg (digest == null || tag != null)
        "kix.options.image: digest ${digest} is set without the tag it was resolved from. Pass `tag` too.";
      let
        hasDefault = repository != null && tag != null;
        default = {
          inherit
            repository
            tag
            digest
            pullPolicy
            ;
        };
        # Use `__pretty` so `toPretty` renders `tagText` as a literal expression
        # rather than a quoted string.
        shownDefault = default // {
          tag = {
            __pretty = lib.id;
            val = tagText;
          };
        };
      in
      lib.mkOption {
        inherit description;
        type = lib.types.submodule (
          { config, ... }:
          {
            options = {
              repository = lib.mkOption (
                {
                  type = lib.types.str;
                  description = "Image repository, registry host included.";
                }
                // lib.optionalAttrs (repository != null) { default = repository; }
              );
              tag = lib.mkOption (
                {
                  type = lib.types.str;
                  description = "Image tag. What was asked for.";
                }
                // lib.optionalAttrs (tag != null) { default = tag; }
                // lib.optionalAttrs (tagText != null) { defaultText = lib.literalExpression tagText; }
              );
              digest = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = if tag != null && config.tag == tag then digest else null;
                defaultText = lib.literalMD "the package's digest while `tag` is the package's tag, otherwise null";
                description = "Resolved manifest digest, `sha256:` followed by 64 hex characters. What will actually run. Null means not resolved.";
              };
              pullPolicy = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = pullPolicy;
                description = "imagePullPolicy for containers using this image. Null leaves it to Kubernetes.";
              };
              sourceRev = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Revision of the source the image was built from, when Kix built it. Null for upstream images.";
              };
              promotedBy = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Who resolved this pin, for the record. Null when unknown.";
              };
              resolvedAt = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "When this pin was resolved, RFC 3339. Null when unknown.";
              };
              note = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Whatever a person wanted to say about this pin. Kix never reads it and a promotion never discards it. Declared here for the same reason as the three fields above: a pin carries its own record-keeping, and the option accepts the whole pin rather than a subset of it.";
              };
            };
          }
        );
      }
      // (
        if hasDefault then
          { inherit default; }
        else
          {
            default = { };
            defaultText = lib.literalMD "none: an instance sets ${
              lib.concatMapStringsSep " and " (f: "`${f}`") (
                lib.optional (repository == null) "repository" ++ lib.optional (tag == null) "tag"
              )
            }";
          }
      )
      // lib.optionalAttrs (hasDefault && tagText != null) {
        defaultText = lib.literalExpression (
          lib.generators.toPretty {
            multiline = true;
            allowPrettyValues = true;
          } shownDefault
        );
      };

    # Build a container `resources` submodule option (`requests`, `limits`, and
    # `claims`) that evaluates to a cleaned Kubernetes `ResourceRequirements`
    # attrset.
    #
    # Package defaults may set `cpu`, `memory`, and `ephemeral-storage`.
    # Instances may also set `hugepages-<size>` and extended resources (such as
    # `nvidia.com/gpu`) or set a field to null to clear its default.
    resources =
      {
        requests ? { },
        limits ? { },
        description ? "Container resource requests and limits. Each field keeps its default until set, and null removes a default.",
      }:
      let
        known = [
          "cpu"
          "memory"
          "ephemeral-storage"
        ];
        badDefaults = builtins.filter (k: !(builtins.elem k known)) (
          builtins.attrNames requests ++ builtins.attrNames limits
        );
        side =
          defaults:
          lib.mkOption {
            type = lib.types.submodule {
              freeformType = lib.types.attrsOf types.quantity;
              options = lib.genAttrs known (
                name:
                lib.mkOption {
                  type = lib.types.nullOr types.quantity;
                  default = defaults.${name} or null;
                  description = "The ${name} quantity. Null leaves it unset.";
                }
              );
            };
            default = { };
            description = "Resource quantities by name.";
          };
        shownDefault = cleanResources {
          inherit requests limits;
          claims = null;
        };
      in
      if badDefaults != [ ] then
        throw "kix.options.resources: defaults may set cpu, memory and ephemeral-storage; ${lib.concatStringsSep ", " badDefaults} is not one of them."
      else
        lib.mkOption {
          inherit description;
          default = { };
          defaultText = lib.literalExpression (lib.generators.toPretty { } shownDefault);
          type = lib.types.submodule {
            options = {
              requests = side requests;
              limits = side limits;
              claims = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.listOf (
                    lib.types.submodule {
                      options = {
                        name = lib.mkOption {
                          type = lib.types.str;
                          description = "Name of an entry in the pod's `resourceClaims`.";
                        };
                        request = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "Request within the claim to use. Null uses the whole claim.";
                        };
                      };
                    }
                  )
                );
                default = null;
                description = "Dynamic resource claims the container uses. Null leaves it unset.";
              };
            };
          };
          apply = cleanResources;
        };

    # Extra container environment variables, merged via `kix.mergeEnv` so
    # package-owned variables cannot be overridden.
    env = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.nullOr (
          lib.mkOptionType {
            name = "envValue";
            description = "string or env var source with `valueFrom`";
            descriptionClass = "noun";
            check = v: builtins.isString v || (builtins.isAttrs v && v ? valueFrom);
            merge = lib.options.mergeEqualOption;
          }
        )
      );
      default = { };
      description = "Extra environment variables. A value is a string, a `fieldRef` source such as `{ valueFrom.fieldRef.fieldPath = \"metadata.name\"; }`, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. A credential that comes from a dependency is wired by the package. Null removes a variable the package sets by default.";
    };

    ingress = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Ingress hostname. Null = auto-derive from cluster.domain.";
      };
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra ingress annotations.";
      };
    };

    monitor = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable metrics endpoint and monitoring resources (ServiceMonitor, PrometheusRules) when prometheus is available.";
      };
      interval = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Scrape interval (e.g. \"30s\"). Null = use Prometheus default.";
      };
    };

    # Options read by `kix.healthCheck` for packages that define a post-deploy
    # probe.
    healthCheck = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run the package's post-deploy probe (kix.healthCheck) once its resources are ready. A failing probe fails the deploy before the activation switches.";
      };
      retryFor = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = "Seconds the probe keeps re-checking before it gives up, so a target still restarting from the rollout does not fail the deploy. The Job's deadline is sized from it.";
      };
    };
  };

  # Build a post-deploy health probe as a `<partName>Script` ConfigMap and a
  # `<partName>` Job in the package namespace.
  #
  # Addresses passed in `env` from `out.*` carry dependency and network-policy
  # context, ordering the Job after its targets and granting egress. The Job
  # sets `kix.run/rerun = "on-change"` so Kix recreates it when its spec
  # changes or after a failed run.
  #
  # `RETRY_FOR` gives the script its retry window in seconds, and
  # `activeDeadlineSeconds` adds `roundBudget` for one final check round. Probe
  # pod labels are disjoint from the package selector so package Services never
  # route traffic to the probe.
  healthCheck =
    let
      imageRef = image.ref;

      # Reserve 90s after the retry window so one final check round can finish
      # before `activeDeadlineSeconds` expires.
      roundBudget = 90;

      # Update digests with `crane digest <repository>:<tag>` (multi-arch index
      # digest).
      runtimes = {
        python = {
          image = {
            repository = "docker.io/library/python";
            tag = "3.13-slim";
            digest = "sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285";
          };
          file = "health-check.py";
          interpreter = [ "python3" ];
          # Skip bytecode writes because `/` and `/probe` are read-only.
          env.PYTHONDONTWRITEBYTECODE = "1";
        };
        shell = {
          image = {
            repository = "docker.io/curlimages/curl";
            tag = "8.14.1";
            digest = "sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b";
          };
          file = "health-check.sh";
          interpreter = [
            "/bin/sh"
            "-eu"
          ];
          env = { };
        };
      };
    in
    {
      inherit runtimes roundBudget;
      __functor =
        _:
        # Callbacks receive `{ self, config, deps }`.
        {
          script,
          # Return an attrset of environment variables for the probe container.
          # Values from `out.*` carry dependency and network-policy context.
          env ? (_: { }),
          # Return false to omit the probe resources.
          when ? ({ config, ... }: config.healthCheck.enabled or true),
          # Return the retry window in seconds (`RETRY_FOR`).
          retryFor ? ({ config, ... }: config.healthCheck.retryFor or 90),
          # Return extra resources the probe Job must wait for in addition to
          # `self.root`.
          requires ? (_: [ ]),
          partName ? "healthCheck",
          runtime ? runtimes.python,
          # Override `activeDeadlineSeconds`. Must be at least
          # `retryFor + roundBudget`.
          activeDeadlineSeconds ? null,
          ttlSecondsAfterFinished ? 3600,
        }:
        {
          self,
          config,
          scope,
          deps,
          ...
        }:
        let
          name = scope.instanceName;
          scriptPart = "${partName}Script";
          ctx = {
            inherit self config deps;
          };
          retry = retryFor ctx;
          deadline = if activeDeadlineSeconds == null then retry + roundBudget else activeDeadlineSeconds;
          userEnv = env ctx;
          rootRes =
            let
              r = self.root;
            in
            r.resource or r;
          # Avoid adding `rootRes` to `requires` when `userEnv` already
          # references it, which would trigger a redundant-requires warning.
          dialsRoot = builtins.hasAttr (builtins.unsafeDiscardStringContext rootRes.outPath) (
            builtins.getContext (builtins.toJSON userEnv)
          );
        in
        if !(when ctx) then
          { }
        else if deadline < retry + roundBudget then
          throw "kix.healthCheck (${name}): activeDeadlineSeconds ${toString deadline} leaves no room for a round of checks after the ${toString retry}s retry window; it must be at least ${toString (retry + roundBudget)}"
        else
          {
            ${scriptPart} = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-health-script";
              data.${runtime.file} = script;
            };

            ${partName} =
              {
                name = "${name}-health";
                requires = requires ctx ++ lib.optional (!dialsRoot) rootRes;
                annotations.${kixKeys.rerun} = kixAnnotations.values.rerunOnChange;
                spec = {
                  backoffLimit = 0;
                  activeDeadlineSeconds = deadline;
                  inherit ttlSecondsAfterFinished;
                  template = {
                    metadata.labels = {
                      "app.kubernetes.io/name" = "${name}-health";
                      "app.kubernetes.io/component" = "health-check";
                    };
                    spec = {
                      restartPolicy = "Never";
                      automountServiceAccountToken = false;
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 65534;
                        runAsGroup = 65534;
                        seccompProfile.type = "RuntimeDefault";
                      };
                      containers = [
                        {
                          name = "probe";
                          image = imageRef runtime.image;
                          command = runtime.interpreter ++ [ "/probe/${runtime.file}" ];
                          env = mkEnvVars (
                            (runtime.env or { })
                            // {
                              RETRY_FOR = toString retry;
                            }
                            // userEnv
                          );
                          terminationMessagePolicy = "FallbackToLogsOnError";
                          securityContext = {
                            runAsNonRoot = true;
                            allowPrivilegeEscalation = false;
                            readOnlyRootFilesystem = true;
                            capabilities.drop = [ "ALL" ];
                          };
                          resources = {
                            requests = {
                              cpu = "50m";
                              memory = "64Mi";
                            };
                            limits.memory = "128Mi";
                          };
                        }
                      ];
                    };
                  };
                };
              }
              |> withMountsOn "probe" [
                (mount.configMap self.${scriptPart} {
                  mountPath = "/probe";
                  readOnly = true;
                })
              ]
              |> scope.mkJob;
          };
    };

  # Expose a Service (or a list of path backends) via a Gateway API HTTPRoute
  # or an Ingress resource, and publish route metadata under `exposurePart`.
  expose =
    {
      service ? null,
      paths ? null,
      partName ? "route",
      # Name of the `{ via; host; scheme; url; urlOrNull; }` part (`exposureOf`).
      # Override both `partName` and `exposurePart` on a second `kix.expose` call.
      exposurePart ? "exposure",
      defaultAnnotations ? { },
      port ? null,
      # Per-rule HTTPRoute timeouts in Gateway mode. Ignored in Ingress mode.
      timeouts ? null,
      # When false, require an explicit `config.ingress.host` instead of
      # falling back to `<instance>.<cluster.domain>`.
      deriveHost ? true,
    }:
    {
      self,
      config,
      clusterConfig,
      scope,
      lib,
      gateway ? null,
      ingressNginx ? null,
      clusterIssuer ? null,
      ...
    }:
    let
      name = scope.instanceName;

      _modeCheck =
        if service == null && paths == null then
          throw "kix.expose (${name}): one of `service` or `paths` must be set."
        else if service != null && paths != null then
          throw "kix.expose (${name}): `service` and `paths` are mutually exclusive."
        else
          null;

      svc = if service != null then self.${service} else null;

      info = exposureOf {
        inherit
          name
          config
          clusterConfig
          scope
          gateway
          ingressNginx
          clusterIssuer
          deriveHost
          ;
      };

      effectiveHost = info.rawHost;
      hasExposure = info.via != null;
      useGateway = info.via == "gateway";
      useIngress = info.via == "ingress";
      hasTls = useIngress && clusterIssuer != null;
      tlsSecretName = "${name}-tls";

      configAnnotations = (config.ingress or { }).annotations or { };

      multiPathRules =
        let
          buildPath =
            p:
            let
              backendSvc = self.${p.service};
              autoPort =
                if backendSvc ? out.port then
                  builtins.fromJSON (builtins.unsafeDiscardStringContext backendSvc.out.port)
                else
                  throw "kix.expose (${name}): paths entry for service '${p.service}' has no out.port. Specify `port` explicitly.";
              svcPort = p.port or autoPort;
            in
            {
              inherit (p) path;
              pathType = p.pathType or "Prefix";
              backend.service = {
                name = backendSvc.out.name;
                port.number = svcPort;
              };
            };
        in
        [
          {
            host = effectiveHost;
            http.paths = map buildPath paths;
          }
        ];

      # Under default-deny network policy, allow the ingress controller or
      # gateway data plane to reach each exposed backend on its target pod port.
      backends =
        if paths != null then
          map (p: {
            part = p.service;
            svc = self.${p.service};
            port = p.port or null;
          }) paths
        else
          [
            {
              part = service;
              inherit svc port;
            }
          ];

      routerOut =
        if useGateway then
          gateway.out
        else if useIngress then
          ingressNginx.out or { }
        else
          { };
      controllerSelector = routerOut.podSelector or null;
      controllerNamespace = routerOut.podNamespace or null;

      wantsControllerEdge = hasExposure && scope.networkPolicyEnforcer != null;

      _controllerEdgeWarn =
        if wantsControllerEdge && useIngress && controllerSelector == null then
          lib.warn (
            "kix.expose (${name}): the ingress controller does not publish `out.podSelector` "
            + "and `out.podNamespace`, so no network policy opens the backend to it. Under "
            + "default deny every request through this Ingress will time out. Add both to the "
            + "controller package's root `out`."
          )
        else if wantsControllerEdge && useGateway && controllerSelector == null then
          let
            gw = gateway.out.gatewayRef;
          in
          lib.warn (
            "kix.expose (${scope.namespaceName}/${name}): Gateway ${gw.namespace}/${gw.name} publishes "
            + "no `out.podSelector`, so no network policy opens the backend to its data-plane pods. "
            + "Under default deny every request through this HTTPRoute will time out. Write a policy "
            + "outside Kix that admits the gateway's proxy pods to the backend, or use a gateway "
            + "package that publishes its pods (traefik)."
          )
        else
          lib.id;

      # Resolve the backend pod ports corresponding to the routed Service port.
      podPortsFor =
        b:
        let
          servicePort = resolveServicePort "kix.expose (${name})" b.port b.svc;
          declared = b.svc.rawManifest.spec.ports or [ ];
          matched = builtins.filter (p: (p.port or null) == servicePort) declared;
        in
        if matched == [ ] then declared else matched;

      controllerEdgeFor =
        b:
        scope.networkPolicyEnforcer.netpol.mkPolicy {
          mkResource = scope.mkResource;
          extraArgs = {
            # Use the Kubernetes Service name rather than the Nix part key,
            # which may be camelCase (such as `coreService`).
            name = "${b.svc.name}-from-${if useGateway then "gateway" else "ingress-controller"}";
            labels = {
              ${kixKeys.derived} = "true";
              ${kixKeys.policyType} = if useGateway then "gateway" else "ingress-controller";
            };
            spec = {
              endpointSelector.matchLabels = b.svc.rawManifest.spec.selector or { };
              ingress = [
                (scope.networkPolicyEnforcer.netpol.mkCallerIngressRule {
                  callerSelector = controllerSelector;
                  callerNamespace = controllerNamespace;
                  ports = podPortsFor b;
                })
              ];
            };
            # Attach the policy to the Service so it is included in the built
            # resource graph even though `spec.selector` has no string context.
            extraDeps = [ b.svc ];
          };
        };

      # Reference the external HTTPRoute CRD so the route is ordered after it.
      routeCrd = scope.mkCRDRef {
        group = "gateway.networking.k8s.io";
        kind = "HTTPRoute";
        plural = "httproutes";
        version = "v1";
      };

      controllerEdgeParts =
        if !(wantsControllerEdge && controllerSelector != null) then
          { }
        else
          builtins.listToAttrs (
            map (b: {
              name = "${partName}-netpol-${b.part}";
              value = controllerEdgeFor b;
            }) backends
          );
    in
    builtins.seq _modeCheck (
      controllerEdgeParts
      // lib.optionalAttrs (hasExposure && useGateway) {
        "${partName}Crd" = routeCrd;
      }
      // {
        # Tag the record with `_type` so part walkers (`collectTypedAttrs` in
        # `eval/helpers.nix`) do not descend into it and force `url`.
        ${exposurePart} = {
          _type = "kix-exposure";
          inherit (info)
            via
            host
            scheme
            url
            urlOrNull
            ;
        };

        # Force `info.scheme` so listener validation runs even when no consumer
        # reads `exposure.url`.
        ${partName} =
          if hasExposure && useGateway then
            builtins.seq info.scheme (
              if paths != null then
                scope.mkCR routeCrd (
                  httpRoute.fromPaths (
                    {
                      inherit name;
                      host = effectiveHost;
                      parentRef = gateway.out.gatewayRef;
                      paths = map (p: {
                        inherit (p) path;
                        pathType = p.pathType or "Prefix";
                        svc = self.${p.service};
                        port = p.port or null;
                      }) paths;
                    }
                    // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
                  )
                )
              else
                svc
                |> httpRoute.fromService (
                  {
                    inherit name;
                    host = effectiveHost;
                    parentRef = gateway.out.gatewayRef;
                  }
                  // lib.optionalAttrs (port != null) { inherit port; }
                  // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
                )
                |> scope.mkCR routeCrd
            )
            |> _controllerEdgeWarn

          else if hasExposure && useIngress then
            (
              if paths != null then
                {
                  apiVersion = "networking.k8s.io/v1";
                  kind = "Ingress";
                  inherit name;
                  annotations = defaultAnnotations // configAnnotations;
                  spec = {
                    ingressClassName = ingressNginx.out.ingressClassName;
                    rules = multiPathRules;
                  }
                  // lib.optionalAttrs hasTls {
                    tls = [
                      {
                        hosts = [ effectiveHost ];
                        secretName = tlsSecretName;
                      }
                    ];
                  };
                }
              else
                svc
                |> ingress.fromService (
                  {
                    inherit name;
                    host = effectiveHost;
                    className = ingressNginx.out.ingressClassName;
                    tls = lib.optional hasTls {
                      hosts = [ effectiveHost ];
                      secretName = tlsSecretName;
                    };
                    annotations = defaultAnnotations // configAnnotations;
                  }
                  // lib.optionalAttrs (port != null) { inherit port; }
                )
            )
            |> (if hasTls then clusterIssuer.out.withCert else lib.id)
            |> _controllerEdgeWarn
            |> scope.mkResource

          else
            null;
      }
    );

  # Build a ServiceMonitor and optional PrometheusRule for a Service.
  #
  # Override `name`, `monitorPart`, and `rulesPart` when a package monitors
  # multiple Services. `scheme`, `tlsConfig`, and `params` apply only to the
  # primary endpoint. `extraEndpoints` inherit `scheme = "http"`,
  # `path = "/metrics"`, and `config.metrics.interval`.
  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      scheme ? "http",
      tlsConfig ? null,
      params ? null,
      alerts ? { },
      extraEndpoints ? [ ],
      extraLabels ? { },
      name ? null,
      monitorPart ? "serviceMonitor",
      rulesPart ? "prometheusRules",
    }:
    {
      self,
      config,
      scope,
      lib,
      prometheus ? null,
      ...
    }@args:
    let
      monitorName = if name != null then name else scope.instanceName;
      svc = self.${service};

      metricsConfig = config.metrics or { };
      metricsEnabled = (metricsConfig.enabled or true) && prometheus != null;
      scrapeInterval = (metricsConfig.interval or null);

      intervalAttrs = lib.optionalAttrs (scrapeInterval != null) {
        interval = scrapeInterval;
      };
      primaryEndpoint = {
        port = if builtins.isInt port then null else port;
        targetPort = if builtins.isInt port then port else null;
        inherit
          scheme
          path
          tlsConfig
          params
          ;
      }
      // intervalAttrs;
      extraEndpoint =
        e:
        {
          scheme = "http";
          path = "/metrics";
        }
        // intervalAttrs
        // e;
      endpoints = [
        (lib.filterAttrs (_: v: v != null) primaryEndpoint)
      ]
      ++ map extraEndpoint extraEndpoints;
    in
    {
      ${monitorPart} =
        if metricsEnabled then
          prometheus.out.mkServiceMonitor scope {
            name = monitorName;
            labels = extraLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = svc.out.selector;
              inherit endpoints;
            };
          }
        else
          null;
    }
    // alertsPart {
      inherit alerts extraLabels rulesPart;
      name = monitorName;
    } args;

  # Build a `<name>-alerts` PrometheusRule part for packages that do not use a
  # single `kix.monitor` ServiceMonitor. Renders only when `prometheus` is
  # wired, `metrics.enabled` is not false, and `alerts` is non-empty.
  alerts =
    {
      alerts,
      name ? null,
      extraLabels ? { },
      rulesPart ? "prometheusRules",
    }:
    alertsPart {
      inherit
        alerts
        name
        extraLabels
        rulesPart
        ;
    };
}
