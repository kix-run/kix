# Build Ingress, Gateway API HTTPRoute, and `kix.expose` route parts.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  gatewayContract = (import ../../contracts { inherit lib; }).gateway;

  resolveServicePort =
    caller: port: svc:
    if port != null then
      port
    else if svc ? out.port then
      builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
    else
      fail {
        message = "${caller}: service '${svc.name or "unknown"}' has no out.port.";
        fix = "Specify port explicitly.";
      };

  # Select the Gateway listener that an HTTPRoute for `host` in `scope` attaches
  # to, returning `{ scheme; port; }` or null when the gateway does not publish
  # `out.listeners`.
  #
  # Matches HTTP and HTTPS listeners whose `hostname` is unset, exact, or a
  # matching `*.` wildcard, and whose `allowedRoutes.namespaces.from` admits
  # the route namespace (`Same` when unset). A `Selector` on the label
  # `kubernetes.io/metadata.name`, which every namespace carries with its own
  # name, is checked against the route namespace. Any other selector cannot
  # be verified statically, so its listener is ranked below verified
  # listeners with a warning. Throws when no listener accepts the route.
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

      # The namespaces a selector admits by name, or null when it selects
      # by anything else.
      nameLabel = "kubernetes.io/metadata.name";
      namesAdmitted =
        l:
        let
          selector = l.allowedRoutes.namespaces.selector or { };
          labels = selector.matchLabels or { };
          expressions = selector.matchExpressions or [ ];
          byLabel = labels == { ${nameLabel} = labels.${nameLabel} or null; } && expressions == [ ];
          byExpression =
            labels == { }
            && builtins.length expressions == 1
            && (builtins.head expressions).key or null == nameLabel
            && (builtins.head expressions).operator or null == "In";
        in
        if byLabel then
          [ labels.${nameLabel} ]
        else if byExpression then
          (builtins.head expressions).values or [ ]
        else
          null;

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
          if namesAdmitted l == null then
            "unverified"
          else if builtins.elem routeNs (namesAdmitted l) then
            "verified"
          else
            "allowedRoutes.namespaces.selector allows only ${
              lib.concatMapStringsSep ", " (n: "\"${n}\"") (namesAdmitted l)
            }"
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
      fail (
        {
          message = "kix.expose (${name}): ${gwLabel} has no HTTP or HTTPS listener that accepts host \"${host}\" from namespace \"${routeNs}\", so the HTTPRoute would not attach. Checked: ${
            if judged == [ ] then "no listeners" else checked
          }.";
          fix = "Allow namespace \"${routeNs}\" on a matching listener of the Gateway instance, or set ingress.host (or ingress.extraHosts) to a hostname an existing listener accepts.";
        }
        # A selector on the namespace's name passed with a warning in
        # earlier releases, so its refusal carries the change record's id.
        //
          lib.optionalAttrs (builtins.any (j: lib.hasPrefix "allowedRoutes.namespaces.selector" j.v) judged)
            {
              id = "K6232";
            }
      )
    else
      {
        inherit (chosen) scheme;
        inherit (chosen.l) port;
        warnings = lib.optional (chosen.v == "unverified") (
          "HTTPRoute '${name}' uses ${gwLabel} listener '${chosen.l.name}', which restricts "
          + "namespaces with a label selector (`allowedRoutes.namespaces.from = \"Selector\"`). "
          + "Kix only checks selectors on the `kubernetes.io/metadata.name` label, so it assumes namespace '${routeNs}' matches "
          + "when computing the route's URL. Make sure namespace '${routeNs}' matches the "
          + "listener's selector, or set `allowedRoutes.namespaces.from = \"All\"` on the listener."
        );
      };

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
      configHost = config.ingress.host or null;
      candidateHost =
        if configHost != null then
          configHost
        else if deriveHost && publicDomain != null then
          "${name}.${publicDomain}"
        else
          null;

      # Ignore unrelated instances named `gateway` (such as an OpenTelemetry
      # Collector) that do not claim the gateway contract.
      hasGateway = gateway != null && gatewayContract.helpers.claims gateway;
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
            fail {
              message = "kix.expose (${name}): both 'gateway' and 'ingressNginx' are present.";
              fix = "Wire exactly one via deps in the cluster definition.";
            }
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
      # Warnings about the route, which `kix.expose` attaches to it.
      warnings = if listener != null then listener.warnings else [ ];
      url =
        if urlOrNull != null then
          urlOrNull
        else
          fail {
            message = "kix.expose (${scope.namespaceName}/${name}): the package reads the instance's public URL (exposure.url), but ${missing}.";
            fix = "If the package has an option for its URL, set that instead.";
          };
    };
in
rec {
  inherit resolveServicePort;

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

  # Map an Ingress `pathType` to a Gateway API path match type so `paths`
  # entries work in both Ingress and Gateway modes.
  gatewayPathType =
    caller: t:
    if t == "Prefix" || t == "PathPrefix" then
      "PathPrefix"
    else if t == "Exact" then
      "Exact"
    else
      fail {
        message = "${caller}: pathType \"${toString t}\" has no Gateway API equivalent.";
        fix = "Use Prefix or Exact.";
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
        # Further hostnames after `host`, filters added to the rule, and
        # whole rules placed before it.
        extraHosts ? [ ],
        filters ? [ ],
        extraRules ? [ ],
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
          "extraHosts"
          "filters"
          "extraRules"
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
          hostnames = [ host ] ++ extraHosts;
          rules = extraRules ++ [
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
              // lib.optionalAttrs (filters != [ ]) { inherit filters; }
            )
          ];
        };
      }
      // passthrough;

    # Build an HTTPRoute with one rule per entry in `paths`.
    fromPaths =
      {
        name,
        host,
        parentRef,
        timeouts ? null,
        extraHosts ? [ ],
        filters ? [ ],
        extraRules ? [ ],
        annotations ? { },
        # List of `{ path; pathType ? "Prefix"; svc; port ? null; }`.
        paths,
      }:
      {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        inherit name annotations;
        spec = {
          parentRefs = [
            (
              {
                name = parentRef.name;
              }
              // lib.optionalAttrs (parentRef ? namespace) { namespace = parentRef.namespace; }
            )
          ];
          hostnames = [ host ] ++ extraHosts;
          rules =
            extraRules
            ++ map (
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
              // lib.optionalAttrs (filters != [ ]) { inherit filters; }
            ) paths;
        };
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
      # The instance's `ingress.timeouts` replaces them.
      timeouts ? null,
      # Gateway API HTTPRouteFilter entries added to every rule the route
      # builds, and whole HTTPRouteRule entries placed before them, such as
      # a redirect on one exact path. Both need a Gateway: with an Ingress
      # the build fails, because an Ingress has neither.
      filters ? [ ],
      extraRules ? [ ],
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
          fail "kix.expose (${name}): one of `service` or `paths` must be set."
        else if service != null && paths != null then
          fail "kix.expose (${name}): `service` and `paths` are mutually exclusive."
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

      configAnnotations = config.ingress.annotations or { };
      routeAnnotations = defaultAnnotations // configAnnotations;
      extraHosts = config.ingress.extraHosts or [ ];
      hosts = [ effectiveHost ] ++ extraHosts;
      instanceTimeouts = config.ingress.timeouts or null;
      effectiveTimeouts =
        if instanceTimeouts == null then timeouts else lib.filterAttrs (_: v: v != null) instanceTimeouts;

      # Every further hostname must attach to a listener too.
      extraHostListeners =
        if useGateway then
          map (
            host:
            gatewayListener {
              inherit name host scope;
              gateway = gatewayContract.require "kix.expose (${scope.namespaceName}/${name})" gateway;
            }
          ) extraHosts
        else
          [ ];
      extraHostWarnings = lib.concatMap (l: if l == null then [ ] else l.warnings) extraHostListeners;

      _ingressCheck =
        if useIngress && (filters != [ ] || extraRules != [ ]) then
          fail {
            message = "kix.expose (${scope.namespaceName}/${name}): this package configures HTTPRoute ${
              if filters != [ ] then "filters" else "rules"
            }, which Kubernetes Ingress resources do not support, and this instance is routed through ingressNginx.";
            fix = "Route this instance through a Gateway API package (such as `envoy-gateway` or `traefik`) instead of `ingress-nginx`, or wire `deps.gateway` in place of `deps.ingressNginx`.";
          }
        else
          null;

      # The Gateway-mode additions every route builder takes.
      routeExtras =
        lib.optionalAttrs (effectiveTimeouts != null && effectiveTimeouts != { }) {
          timeouts = effectiveTimeouts;
        }
        // lib.optionalAttrs (extraHosts != [ ]) { inherit extraHosts; }
        // lib.optionalAttrs (filters != [ ]) { inherit filters; }
        // lib.optionalAttrs (extraRules != [ ]) { inherit extraRules; }
        // lib.optionalAttrs (routeAnnotations != { }) { annotations = routeAnnotations; };

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
                  fail {
                    message = "kix.expose (${name}): paths entry for service '${p.service}' has no out.port.";
                    fix = "Specify `port` explicitly.";
                  };
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
        map (host: {
          inherit host;
          http.paths = map buildPath paths;
        }) hosts;

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

      # A controller edge is an ingress-only policy. Where the cluster does
      # not enforce ingress, it would be the first ingress policy on the
      # backend and close it to every other client.
      wantsControllerEdge =
        hasExposure && scope.networkPolicyEnforcer != null && scope.networkPolicyEnforced.ingress;

      controllerEdgeWarnings =
        if wantsControllerEdge && useIngress && controllerSelector == null then
          [
            (
              "Ingress '${name}': the ingress controller does not publish `out.podSelector` "
              + "and `out.podNamespace`, so Kix did not create a network policy allowing traffic "
              + "from the controller to the backend pods. Under default-deny ingress, requests "
              + "through this Ingress will time out. Set `out.podSelector` and `out.podNamespace` "
              + "on the ingress controller's `out` (in its package `root` or `kix.mkImport`), or "
              + "create a network policy outside Kix."
            )
          ]
        else if wantsControllerEdge && useGateway && controllerSelector == null then
          let
            gw = gateway.out.gatewayRef;
          in
          [
            (
              "HTTPRoute ${scope.namespaceName}/${name}: Gateway ${gw.namespace}/${gw.name} does not "
              + "publish `out.podSelector` and `out.podNamespace`, so Kix did not create a network "
              + "policy allowing traffic from the gateway's proxy pods to the backend pods. Under "
              + "default-deny ingress, requests through this HTTPRoute will time out. Set "
              + "`out.podSelector` and `out.podNamespace` on the gateway's `out`, use a gateway "
              + "package that publishes them (`traefik` or `envoy-gateway`), or create a network "
              + "policy outside Kix."
            )
          ]
        else
          [ ];

      # A Service without a selector (ExternalName, or one backed by
      # EndpointSlices managed elsewhere) names no pods, and an empty
      # endpoint selector would admit the controller to every pod in the
      # namespace.
      selectorOf = b: b.svc.rawManifest.spec.selector or { };
      selectorlessBackends = builtins.filter (b: selectorOf b == { }) backends;
      selectorlessWarnings =
        lib.optional (wantsControllerEdge && controllerSelector != null && selectorlessBackends != [ ])
          (
            "Route ${scope.namespaceName}/${name}: no pod selector (`spec.selector`) is set on Service "
            + lib.concatMapStringsSep ", " (b: b.svc.name) selectorlessBackends
            + ", so Kix did not create a network policy allowing traffic from the "
            + (if useGateway then "gateway's proxy pods" else "ingress controller")
            + " to its endpoints. If those endpoints are pods under default-deny ingress, "
            + "requests will time out until you create a network policy outside Kix."
          );

      # cert-manager answers an HTTP-01 challenge from solver pods it starts
      # in the Ingress's namespace, and the ingress controller forwards the
      # challenge request to them.
      acmeSolverSelector = if hasTls then clusterIssuer.out.http01SolverSelector or null else null;
      acmeSolverPort = 8089;

      # An issuer that is not the cluster-issuer package, such as a
      # kix.mkImport, does not say whether it solves HTTP-01.
      acmeUnknownWarnings =
        lib.optional (wantsControllerEdge && hasTls && !(clusterIssuer.out ? http01SolverSelector))
          (
            "Ingress ${scope.namespaceName}/${name}: the `clusterIssuer` dependency does not set "
            + "`out.http01SolverSelector`, so Kix cannot tell whether it uses ACME HTTP-01 challenges "
            + "and did not create a network policy for cert-manager's solver pods. Under default-deny "
            + "ingress, HTTP-01 certificate challenges will fail unless TCP port 8089 is open from the "
            + "ingress controller to pods with label `acme.cert-manager.io/http01-solver=true` in this "
            + "namespace. On the `clusterIssuer` import or package, set `out.http01SolverSelector = "
            + "{ \"acme.cert-manager.io/http01-solver\" = \"true\"; };` for an HTTP-01 issuer (so Kix "
            + "creates that policy), or `out.http01SolverSelector = null;` otherwise."
          );

      # Attach the route's warnings to the route resource as `_warnings`,
      # which the instance collects into its warnings.
      withRouteWarnings =
        route:
        route
        // {
          _warnings =
            (route._warnings or [ ])
            ++ info.warnings
            ++ extraHostWarnings
            ++ controllerEdgeWarnings
            ++ selectorlessWarnings
            ++ acmeUnknownWarnings;
        };

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
              endpointSelector.matchLabels = selectorOf b;
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

      acmeSolverEdge = scope.networkPolicyEnforcer.netpol.mkPolicy {
        mkResource = scope.mkResource;
        extraArgs = {
          name = "${name}-acme-solver-from-ingress-controller";
          labels = {
            ${kixKeys.derived} = "true";
            ${kixKeys.policyType} = "ingress-controller";
          };
          spec = {
            endpointSelector.matchLabels = acmeSolverSelector;
            ingress = [
              (scope.networkPolicyEnforcer.netpol.mkCallerIngressRule {
                callerSelector = controllerSelector;
                callerNamespace = controllerNamespace;
                ports = [
                  {
                    port = acmeSolverPort;
                    protocol = "TCP";
                  }
                ];
              })
            ];
          };
          extraDeps = [ ];
        };
      };

      controllerEdgeParts =
        if !(wantsControllerEdge && controllerSelector != null) then
          { }
        else
          builtins.listToAttrs (
            map (b: {
              name = "${partName}-netpol-${b.part}";
              # The part names must not read the Services, which are parts
              # of the same instance, so a selectorless backend's part is
              # null rather than absent.
              value = if selectorOf b == { } then null else controllerEdgeFor b;
            }) backends
          )
          // lib.optionalAttrs (acmeSolverSelector != null) {
            "${partName}-netpol-acme-solver" = acmeSolverEdge;
          };
    in
    builtins.seq _modeCheck (builtins.seq _ingressCheck) (
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
            builtins.seq info.scheme (builtins.deepSeq (map (l: l.scheme or null) extraHostListeners)) (
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
                    // routeExtras
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
                  // routeExtras
                )
                |> scope.mkCR routeCrd
            )
            |> withRouteWarnings

          else if hasExposure && useIngress then
            (
              if paths != null then
                {
                  apiVersion = "networking.k8s.io/v1";
                  kind = "Ingress";
                  inherit name;
                  annotations = routeAnnotations;
                  spec = {
                    ingressClassName = ingressNginx.out.ingressClassName;
                    rules = multiPathRules;
                  }
                  // lib.optionalAttrs hasTls {
                    tls = [
                      {
                        inherit hosts;
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
                      inherit hosts;
                      secretName = tlsSecretName;
                    };
                    annotations = routeAnnotations;
                  }
                  // lib.optionalAttrs (port != null) { inherit port; }
                )
                # One rule per hostname, each with the same paths.
                |> (
                  ing:
                  ing
                  // {
                    spec = ing.spec // {
                      rules = lib.concatMap (host: map (rule: rule // { inherit host; }) ing.spec.rules) hosts;
                    };
                  }
                )
            )
            |> (if hasTls then clusterIssuer.out.withCert else lib.id)
            |> scope.mkResource
            |> withRouteWarnings

          else
            null;
      }
    );
}
