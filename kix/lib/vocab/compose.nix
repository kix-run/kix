{ lib }:

let
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
      throw "${caller}: service '${svc.name or "unknown"}' has no out.port — specify port explicitly";
in

rec {

  # Typed-fact escape hatches (core/facts.nix), re-exported for package
  # authors: `kix.facts.refOnly svc.out.fqdn` (name it, don't dial it),
  # `kix.facts.connect svc.factTokens.endpoint value` (dial by a value
  # that lacks the claim, e.g. a bare intra-namespace name).
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect;
  };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  mkEnvVars =
    attrs:
    lib.mapAttrsToList (name: value: { inherit name value; }) (lib.filterAttrs (_: v: v != null) attrs);

  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  parseGi =
    s:
    let
      str = builtins.unsafeDiscardStringContext (toString s);
      matchTi = builtins.match "([0-9]+)Ti" str;
      matchGi = builtins.match "([0-9]+)Gi" str;
      matchMi = builtins.match "([0-9]+)Mi" str;
    in
    if matchTi != null then
      (builtins.fromJSON (builtins.head matchTi)) * 1024
    else if matchGi != null then
      builtins.fromJSON (builtins.head matchGi)
    else if matchMi != null then
      (builtins.fromJSON (builtins.head matchMi)) / 1024
    else
      null;

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
          targetPort = cp.name;
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
        badTargets = builtins.filter (
          p:
          (p ? targetPort)
          && builtins.isString p.targetPort
          && !(builtins.elem p.targetPort workloadPortNames)
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
      builtins.seq _portCheck {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        spec = {
          inherit type;
          selector = workload.out.selector;
          ports = finalPorts;
        };
        outputs = autoOutputs // (cfg.outputs or { });
      }
      // removeAttrs passthrough [ "outputs" ];
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
          ];
        };
      }
      // passthrough;
  };

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
          throw "withMounts: multiple containers — use withMountsOn to target a specific one";
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

  untrackedRef =
    name:
    let
      marker = builtins.toFile "kix-untracked-ref" name;
    in
    builtins.appendContext name (builtins.getContext "${marker}");

  options = {
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
  };

  expose =
    {
      service ? null,
      paths ? null,
      partName ? "ingress",
      defaultAnnotations ? { },
      port ? null,
      tlsSecretName ? null,
      tlsSecret ? null,
      tlsSecretPart ? null,
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

      effectiveTlsSecret = if tlsSecretPart != null then self.${tlsSecretPart} else tlsSecret;

      _tlsSecretNsCheck =
        if effectiveTlsSecret != null then
          let
            secretNs =
              if (effectiveTlsSecret.namespace._type or "") == "k8s-cluster-scoped" then
                null
              else
                effectiveTlsSecret.namespace.name or null;
          in
          if secretNs != null && secretNs != scope.namespaceName then
            throw "kix.expose (${name}): tlsSecret '${effectiveTlsSecret.name or "?"}' is in namespace "
            + "\"${secretNs}\" but the Ingress is in namespace \"${scope.namespaceName}\". "
            + "Kubernetes ingress controllers only read TLS secrets from the Ingress's own namespace."
          else
            null
        else if tlsSecretName != null then
          if builtins.getContext tlsSecretName == { } then
            throw "kix.expose (${name}): tlsSecretName \"${tlsSecretName}\" is a raw string literal. "
            + "Use `tlsSecret = someSecretResource` (resource form — also enables cross-namespace validation), "
            + "`tlsSecretName = someSecret.out.name` (tracked string), "
            + "or `tlsSecretName = kix.untrackedRef \"...\"` to opt out explicitly."
          else
            null
        else
          null;

      tlsSecretNameEffective =
        if effectiveTlsSecret != null then
          effectiveTlsSecret.out.name
        else if tlsSecretName != null then
          tlsSecretName
        else
          "${name}-tls";

      clusterDomain = clusterConfig.cluster.domain or null;
      configHost = (config.ingress or { }).host or null;
      effectiveHost =
        if configHost != null then
          configHost
        else if clusterDomain != null then
          "${name}.${clusterDomain}"
        else
          null;

      hasGateway = gateway != null && gateway ? out.gatewayRef;

      hasIngress = ingressNginx != null;

      useGateway =
        hasGateway
        && (
          if hasIngress then
            throw "kix.expose (${name}): both 'gateway' and 'ingressNginx' are present. Wire exactly one via deps in the cluster definition."
          else
            true
        );
      useIngress = hasIngress && !hasGateway;

      hasExposure = (useGateway || useIngress) && effectiveHost != null;
      hasTls = hasExposure && useIngress && clusterIssuer != null;

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
                  throw "kix.expose (${name}): paths entry for service '${p.service}' has no out.port — specify `port` explicitly.";
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
    in
    builtins.seq _modeCheck {
      ${partName} =
        if hasExposure && useGateway then
          if paths != null then
            throw "kix.expose (${name}): `paths` (multi-backend) is not yet supported in Gateway API mode."
          else
            svc
            |> httpRoute.fromService (
              {
                inherit name;
                host = effectiveHost;
                parentRef = gateway.out.gatewayRef;
              }
              // lib.optionalAttrs (port != null) { inherit port; }
            )
            |> scope.mkResource

        else if hasExposure && useIngress then
          builtins.seq _tlsSecretNsCheck (
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
                        secretName = tlsSecretNameEffective;
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
                      secretName = tlsSecretNameEffective;
                    };
                    annotations = defaultAnnotations // configAnnotations;
                  }
                  // lib.optionalAttrs (port != null) { inherit port; }
                )
            )
            |> (if hasTls then clusterIssuer.out.withCert else lib.id)
            |> scope.mkResource
          )

        else
          null;
    };

  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      alerts ? { },
      extraEndpoints ? [ ],
      extraLabels ? { },
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
      name = scope.instanceName;
      svc = self.${service};

      metricsConfig = config.metrics or { };
      metricsEnabled = (metricsConfig.enabled or true) && prometheus != null;
      scrapeInterval = (metricsConfig.interval or null);

      primaryEndpoint = {
        port = if builtins.isInt port then null else port;
        targetPort = if builtins.isInt port then port else null;
        scheme = "http";
        inherit path;
      }
      // lib.optionalAttrs (scrapeInterval != null) {
        interval = scrapeInterval;
      };
      endpoints = [ (lib.filterAttrs (_: v: v != null) primaryEndpoint) ] ++ extraEndpoints;

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
      serviceMonitor =
        if metricsEnabled then
          prometheus.out.mkServiceMonitor scope {
            inherit name;
            labels = extraLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = svc.out.selector;
              inherit endpoints;
            };
          }
        else
          null;

      prometheusRules =
        if metricsEnabled && hasAlerts then
          prometheus.out.mkPrometheusRule scope {
            name = "${name}-alerts";
            labels = extraLabels;
            spec = {
              groups = [
                {
                  name = "${name}-alerts";
                  rules = alertRules;
                }
              ];
            };
          }
        else
          null;
    };

}
