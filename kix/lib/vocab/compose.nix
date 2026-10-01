{ lib }:

let
  markers = import ../core/markers.nix { inherit lib; };

  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  normalize = import ../core/normalize.nix { inherit lib; };

  quantity = import ./quantity.nix { inherit lib; };

  # Resource names a ResourceRequirements map may use besides cpu, memory
  # and ephemeral-storage.
  isResourceName =
    name:
    builtins.elem name [
      "cpu"
      "memory"
      "ephemeral-storage"
    ]
    || builtins.match "hugepages-.+" name != null
    || lib.hasInfix "/" name;

  # The value of `kix.options.resources` with every unset field removed:
  # no null leaves, no empty `requests` or `limits`, no null `claims`.
  # Undeclared resource names are checked here because a freeformType's
  # own `check` never runs; `apply` has no instance name to report.
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

  # The public route kix.expose renders for an instance, as data:
  # { via; host; scheme; url; }. `via` is "gateway", "ingress" or null (no
  # route). `scheme` is null when Kix cannot vouch for it (a gateway without
  # out.listeners, such as a kix.mkImport). It reads config, clusterConfig,
  # scope and the exposure deps, never `self`, so any part can read it.
  # `rawHost` keeps the string context of config.ingress.host for rendering.
  exposureOf =
    {
      name,
      config,
      clusterConfig,
      scope,
      gateway,
      ingressNginx,
      clusterIssuer,
    }:
    let
      publicDomain = clusterConfig.cluster.domain or null;
      configHost = (config.ingress or { }).host or null;
      candidateHost =
        if configHost != null then
          configHost
        else if publicDomain != null then
          "${name}.${publicDomain}"
        else
          null;

      hasGateway = gateway != null && gateway ? out.gatewayRef;
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
              gateway
              ;
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
    in
    {
      inherit
        via
        host
        rawHost
        scheme
        ;
      url = if scheme == null then null else "${scheme}://${host}${portSuffix}";
    };

  # The Gateway listener an HTTPRoute for `host` from the instance's
  # namespace attaches to, matched as Gateway API does: protocol HTTP or
  # HTTPS, `hostname` unset, equal, or a `*.` wildcard covering the host,
  # and `allowedRoutes.namespaces.from` admitting the namespace (unset means
  # Same). Kix does not evaluate a `Selector`, so such a listener is
  # unverified and chosen only after verified ones, with a warning.
  # Returns { scheme; port; } or null when the gateway publishes no
  # listeners. Throws when no listener accepts the route.
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

      # "verified", "unverified" (Selector), or a rejection reason.
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
in

rec {

  # Use kix.keys.<name> for annotation keys defined in core/annotations.nix.
  keys = kixKeys;

  # Package helpers for endpoint facts; see core/facts.nix for their contracts.
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect structural;
  };

  # Image reference helpers. ref renders repository:tag and an optional
  # @digest; a digest selects fixed image content even when the tag moves.
  # These helpers do not validate digest syntax or query a registry.
  #
  #   image = kix.image.ref config.serverImage;
  #   # docker.io/library/nginx:1.27@sha256:0d17b1...
  #
  # Cluster definitions can supply config.serverImage = pins.get "server";
  # from a committed pin file. See pins.nix for loading and validation.
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
      # Render `repository:tag` plus `@digest` when a digest is pinned.
      ref =
        image:
        "${needField image "repository"}:${needField image "tag"}"
        + lib.optionalString (image.digest or null != null) "@${image.digest}";

      # Test whether digest is present and non-null; this does not validate it.
      isPinned = image: (image.digest or null) != null;
    };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  # A value is a string, or a `valueFrom` source such as the one
  # `secret.out.keyRef "password"` returns. The source keeps its dependency
  # context, so `{ DB_PASSWORD = creds.out.keyRef "password"; }` orders the
  # workload after the Secret the same way a string from `out.*` would.
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

  # lib.recursiveUpdate for an escape hatch such as `extraSpec`, refusing an
  # override on any path the package computed for correctness (an address
  # that carries a netpol edge, a credential reference, a quorum size) or
  # that has an option of its own. `locked` is a list of attribute paths;
  # `who` names the package instance and `what` the option, for the error.
  #
  # A locked path is also refused when `overrides` sets one of its ancestors
  # to a value that is not an attribute set: recursiveUpdate would replace
  # the whole subtree, so `{ a = null; }` removes a locked `a.b`.
  mergeGuarded =
    {
      who,
      locked,
      what ? "extraSpec",
    }:
    base: overrides:
    let
      # The proper prefix of `path` that `overrides` sets to a
      # non-attrset, or null when there is none.
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

  # Option types for values Kubernetes parses. `quantity` is the grammar of
  # vocab/quantity.nix: "500m", "1.5Gi", 2.
  types.quantity = quantity.type;

  # The quantity `q` in millicores when `resource` is "cpu", and in bytes
  # otherwise, rounded down. null when `q` is not a quantity.
  #
  #   kix.parseQuantity "memory" "512Mi"   # 536870912
  parseQuantity = quantity.parse;

  # A size in whole GiB, rounded down ("500Mi" gives 0). null when `s` is
  # not a quantity.
  parseGi =
    s:
    let
      bytes = quantity.parse "memory" s;
    in
    if bytes == null then
      null
    else if builtins.isInt bytes then
      bytes / 1073741824
    else
      builtins.floor (bytes / 1073741824);

  # The env attrset for `kix.mkEnvVars`: the package's `defaults`, then the
  # instance's `env` (a `kix.options.env` value), then the variables the
  # package owns. Each entry of `owned` is
  #   { vars ? { }; names ? [ ]; from; fix; }
  # `vars` are added to the result and may not appear in `env`; `names` may
  # not appear in `env` and are delivered another way (an `envFrom`). A key
  # in `env` that a group owns throws, also when its value is null, with
  # one line per group naming `from` and `fix`.
  #
  #   env = kix.mkEnvVars (kix.mergeEnv {
  #     inherit who;
  #     defaults.LOG_LEVEL = "info";
  #     owned = [ {
  #       vars.DB_HOST = database.out.fqdn;
  #       from = "the database dependency";
  #       fix = "Wire a different database instance through deps.database instead.";
  #     } ];
  #   } config.env);
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

  # Returns `args` (an `extraArgs` list) unless it sets a flag the package
  # owns. `owned` maps each flag to the reason and fix shown in the error.
  # An argument sets a flag when it equals the flag or starts with the flag
  # followed by "=", so `--ingress-class-by-name=true` does not set
  # `--ingress-class`. Every hit is reported, one line each.
  #
  #   args = baseArgs ++ kix.guardArgs {
  #     inherit who;
  #     owned."--metrics-bind-address" = "the metrics Service uses :8080; remove it.";
  #   } config.extraArgs;
  guardArgs =
    {
      who,
      option ? "extraArgs",
      owned,
    }:
    args:
    let
      flagOf =
        arg:
        lib.findFirst (flag: arg == flag || lib.hasPrefix "${flag}=" arg) null (builtins.attrNames owned);
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

  # Returns `dep` (a secret dependency, or null for an absent optional one)
  # after checking that its `out.keys` declares every name in `keys` and,
  # when `anyOf` is a list of key groups, every name of at least one group.
  # `arg` is the dependency's argument name, for the error. Read the secret
  # through the returned value, so the check runs before any `keyRef`.
  #
  #   creds = kix.checkSecretKeys {
  #     inherit who;
  #     arg = "cloudCredentials";
  #     dep = cloudCredentials;
  #     keys = [ "cloud" ];
  #   };
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
        # name -> containerPort, for resolving named targetPorts below.
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
        # Resolve named targetPorts while the workload is available. The
        # network-policy layer copies targetPort into egress rules, and Cilium
        # 1.19 drops egress traffic when those policy ports remain named.
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
      # as spec.clusterIP preserve its selector and ports. Recursive update
      # replaces lists as complete values; remove ports above because it has a
      # dedicated argument.
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
        # Gateway API HTTPRoute per-rule timeouts, e.g.
        # { request = "0s"; backendRequest = "0s"; } to disable (needed for
        # long-lived streaming backends). null → omit (Envoy's 15s default).
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

  # Ingress pathType to Gateway API path match type. `paths` entries are
  # written in the Ingress vocabulary so one declaration serves both modes.
  gatewayPathType =
    caller: t:
    if t == "Prefix" || t == "PathPrefix" then
      "PathPrefix"
    else if t == "Exact" then
      "Exact"
    else
      throw "${caller}: pathType \"${toString t}\" has no Gateway API equivalent (use Prefix or Exact)";

  # One HTTPRoute, one rule per path, each to its own backend. The Gateway
  # orders rules by precedence itself, so the list order carries no
  # meaning.
  httpRoute.fromPaths =
    {
      name,
      host,
      parentRef,
      timeouts ? null,
      # [ { path; pathType ? "Prefix"; svc; port ? null } ]
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
        # A ConfigMap volume is read-only whatever the mount says; this
        # writes it on the mount too, where a reader of the pod looks.
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

  options = {
    # Image option with repository, tag, and optional digest and pull policy.
    # A null digest leaves the reference unpinned. A null pullPolicy leaves
    # imagePullPolicy unset, so Kubernetes chooses: Always for `:latest`,
    # IfNotPresent otherwise.
    #
    # An instance that sets only some fields keeps the package's defaults for
    # the rest. The package's digest is kept only while `tag` equals the
    # package's tag, since a digest belongs to the tag it was resolved from.
    #
    #   options.image = kix.options.image {
    #     repository = "docker.io/library/nginx";
    #     tag = "1.27";
    #   };
    #
    # Supply a resolved reference from the cluster's pin file:
    #   config.image = pins.get "web";
    #
    # `tagText` is the Nix expression the option reference shows as the
    # tag's default, for a package whose `config` sets the tag from another
    # option. `tag` stays the declared default the digest rule compares with.
    image =
      {
        repository,
        tag,
        digest ? null,
        pullPolicy ? "IfNotPresent",
        tagText ? null,
        description ? "Container image for this instance. Set it from a pin file (`kix.pins`) so the deployed reference is committed and resolved.",
      }:
      let
        default = {
          inherit
            repository
            tag
            digest
            pullPolicy
            ;
        };
        # toPretty prints a `__pretty` value through its function, so the tag
        # renders as the expression rather than as a quoted string.
        shownDefault = default // {
          tag = {
            __pretty = lib.id;
            val = tagText;
          };
        };
      in
      lib.mkOption {
        inherit description default;
        type = lib.types.submodule (
          { config, ... }:
          {
            options = {
              repository = lib.mkOption {
                type = lib.types.str;
                default = repository;
                description = "Image repository, registry host included.";
              };
              tag =
                lib.mkOption {
                  type = lib.types.str;
                  default = tag;
                  description = "Image tag. What was asked for.";
                }
                // lib.optionalAttrs (tagText != null) { defaultText = lib.literalExpression tagText; };
              digest = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = if config.tag == tag then digest else null;
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
      // lib.optionalAttrs (tagText != null) {
        defaultText = lib.literalExpression (
          lib.generators.toPretty {
            multiline = true;
            allowPrettyValues = true;
          } shownDefault
        );
      };

    # Container resource requests and limits as typed fields. Each default
    # sits on its field, so an instance that sets `limits.memory` keeps the
    # package's `requests`; null removes a default. The value is a
    # ResourceRequirements with unset fields absent, ready for a container's
    # `resources`.
    #
    #   options.resources = kix.options.resources {
    #     requests = { cpu = "100m"; memory = "128Mi"; };
    #     limits.memory = "256Mi";
    #   };
    #
    # Defaults may set cpu, memory and ephemeral-storage. An instance may
    # also set hugepages-<size> and extended resources (nvidia.com/gpu).
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

    # Extra environment variables for a container, rendered with
    # `kix.mergeEnv` so the variables the package owns cannot be replaced.
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

    # For packages with a kix.healthCheck probe; the helper reads both.
    healthCheck = {
      enable = lib.mkOption {
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

  # Build a post-deploy health probe as a Job in the package namespace.
  # Addresses passed from out.* values carry dependency and network-policy
  # context, so the Job runs after its targets and receives matching egress.
  # Job success completes the probe; exhausting backoffLimit fails the deploy.
  #
  #   options.healthCheck = kix.options.healthCheck;   # enable, retryFor
  #   build = [
  #     ({ self, vmCluster, ... }: { ... })
  #     (kix.healthCheck {
  #       env = { self, deps, ... }: {
  #         VMSELECT_URL = deps.vmCluster.out.serviceUrl;
  #         AGENT_REPLICAS = self.vmAgent.out.replicas;
  #       };
  #       script = builtins.readFile ./health-check.py;
  #     })
  #   ];
  #
  # The helper emits a ConfigMap named `<partName>Script` and a Job named
  # `<partName>` that mounts it at /probe. The Job depends on the package root
  # plus `requires`. kix.run/rerun="on-change" recreates the Job after its
  # identity changes or after a failure. An operator reconcile also recreates
  # a completed Job after ttlSecondsAfterFinished removes it.
  #
  # Python is the default runtime. A nonzero exit fails the probe. RETRY_FOR
  # gives the script its retry window, and activeDeadlineSeconds includes that
  # window plus roundBudget for one final check. The script must stop after
  # RETRY_FOR and keep each round within roundBudget. On failure,
  # FallbackToLogsOnError supplies the final log lines to deploy output.
  #
  # Probe labels do not overlap the package selector, which prevents package
  # Services from routing to the probe. The pod runs as nobody with a read-only
  # root filesystem and no service account token.
  healthCheck =
    let
      imageRef = image.ref;

      # Seconds one worst-case round of checks may take: every query timing
      # out, plus the pause before the next round. The deadline always
      # leaves this much room after the retry window. The shipped probes
      # make at most six requests a round at a 10 s timeout, then pause 10 s.
      roundBudget = 90;

      # Bump a digest with `crane digest <repository>:<tag>` (the multi-arch
      # index digest, which is what containerd resolves).
      runtimes = {
        python = {
          image = {
            repository = "docker.io/library/python";
            tag = "3.13-slim";
            digest = "sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285";
          };
          file = "health-check.py";
          interpreter = [ "python3" ];
          # No bytecode cache next to the script: the root filesystem is
          # read-only and /probe is a ConfigMap.
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
        # Every callback receives the same `{ self, config, deps }`: `self`
        # is the package's build result, `config` its evaluated options,
        # `deps` every dependency-injected package some entry of the
        # package declares, keyed by argument name.
        {
          script,
          # -> attrset of env var name to value. Values from `out.*` carry
          # context; that is what gives the Job its edges. Nulls are
          # dropped. `RETRY_FOR` is set by the helper.
          env ? (_: { }),
          # -> bool. False renders nothing. The default reads the option
          # set `kix.options.healthCheck` when the package declares it, and
          # is true when it does not.
          when ? ({ config, ... }: config.healthCheck.enable or true),
          # -> seconds the script keeps re-checking before it gives up.
          # Same default rule as `when`; 90 when the package has no option.
          retryFor ? ({ config, ... }: config.healthCheck.retryFor or 90),
          # -> resources the probe waits for beyond the package root, which
          # it always waits for.
          requires ? (_: [ ]),
          partName ? "healthCheck",
          # { image = { repository; tag; digest; }; file; interpreter; env; }.
          # One of `kix.healthCheck.runtimes`, or a package's own.
          runtime ? runtimes.python,
          # Job deadline. Null sizes it from the retry window; a value must
          # leave `roundBudget` after the window, or the build fails.
          activeDeadlineSeconds ? null,
          # Seconds a finished Job stays before Kubernetes removes it.
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
          # The package root as a resource: a bare part, or the wrapper
          # form `{ resource; out; }`.
          rootRes =
            let
              r = self.root;
            in
            r.resource or r;
          # An env value computed from the root already carries the edge;
          # listing it again would draw the redundant-requires warning.
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

  expose =
    {
      service ? null,
      paths ? null,
      # The Ingress or HTTPRoute part.
      partName ? "route",
      # A plain record part { via; host; scheme; url; } describing that
      # route (exposureOf). Set both names on a second kix.expose call.
      exposurePart ? "exposure",
      defaultAnnotations ? { },
      port ? null,
      # Gateway API mode only: per-rule HTTPRoute timeouts, e.g.
      # { request = "0s"; } to disable the default 15s request timeout for
      # long-lived streaming backends. Ignored in Ingress (nginx) mode.
      timeouts ? null,
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

      # Under default-deny policy, allow the ingress controller to reach each
      # backend on the routed pod port. kix.expose has both the backend Service
      # and the controller dependency needed to derive this rule.
      #
      # Gateway API is excluded because gateway.out supplies a parentRef, not
      # the data-plane pod selector and namespace required by this rule.
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

      controllerSelector = (ingressNginx.out or { }).podSelector or null;
      controllerNamespace = (ingressNginx.out or { }).podNamespace or null;

      wantsControllerEdge = hasExposure && useIngress && scope.networkPolicyEnforcer != null;

      # A policy requires the controller pod selector and namespace. Warn when
      # the controller package does not expose them.
      _controllerEdgeWarn =
        if wantsControllerEdge && controllerSelector == null then
          lib.warn (
            "kix.expose (${name}): the ingress controller does not publish `out.podSelector` "
            + "and `out.podNamespace`, so no network policy opens the backend to it. Under "
            + "default deny every request through this Ingress will time out. Add both to the "
            + "controller package's root `out`."
          )
        else
          lib.id;

      # The rule carries the pod port, not the Service port: the policy
      # lands on the backend's pods.
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
            # The Service's own name, not the part's: a part name is a
            # Nix identifier and `coreService` is not a legal object name.
            name = "${b.svc.name}-from-ingress-controller";
            labels = {
              ${kixKeys.derived} = "true";
              ${kixKeys.policyType} = "ingress-controller";
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
            # The selector above is raw labels and carries no context, so
            # without this the policy is a part no dependency reaches.
            extraDeps = [ b.svc ];
          };
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
      // {
        ${exposurePart} = {
          inherit (info)
            via
            host
            scheme
            url
            ;
        };

        # Forcing info.scheme runs the listener match, so a route that no
        # listener accepts fails the build even when nothing reads the URL.
        ${partName} =
          if hasExposure && useGateway then
            builtins.seq info.scheme (
              if paths != null then
                scope.mkResource (
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
                |> scope.mkResource
            )

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

  # `name`, `monitorPart` and `rulesPart` let a package with several
  # metrics Services (harbor: core, registry, jobservice, exporter) call
  # this once per Service without the parts or the resource names
  # colliding. The defaults are the single-Service case.
  #
  # `scheme` and `tlsConfig` (a ServiceMonitor endpoint `tlsConfig`) apply
  # to the primary endpoint only. Each of `extraEndpoints` is a ServiceMonitor
  # endpoint over the defaults `scheme = "http"`, `path = "/metrics"` and the
  # instance's `metrics.interval` when that is set.
  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      scheme ? "http",
      tlsConfig ? null,
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
    }:
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
        inherit scheme path tlsConfig;
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
      ) alerts;
      hasAlerts = alerts != { };
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

      ${rulesPart} =
        if metricsEnabled && hasAlerts then
          prometheus.out.mkPrometheusRule scope {
            name = "${monitorName}-alerts";
            labels = extraLabels;
            spec = {
              groups = [
                {
                  name = "${monitorName}-alerts";
                  rules = alertRules;
                }
              ];
            };
          }
        else
          null;
    };

}
