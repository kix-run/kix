# kixlib — pure composition helpers for kix packages.
#
# These functions have no scope dependency. They operate on plain attrsets
# and resource objects. Packages receive this as the `kix` argument.
#
# Usage:
#   service = self.deployment
#     |> kix.service.fromWorkload { name = "my-svc"; }
#     |> scope.mkResource;
#
#   ingress = self.service
#     |> kix.ingress.fromService { name = "my-ing"; host = "example.com"; }
#     |> clusterIssuer.out.withCert
#     |> scope.mkResource;
#
#   route = self.service
#     |> kix.httpRoute.fromService { name = "my-route"; host = "example.com"; parentRef = gateway.out.gatewayRef; }
#     |> scope.mkResource;
#
# Mount helpers:
#   libraryMount = kix.mount.pvc storage { mountPath = "/data"; };
#   configMount  = kix.mount.configMap self.configMap { mountPath = "/config"; subPath = "app.conf"; };
#   secretMount  = kix.mount.secret self.secret { mountPath = "/keys"; items = [{ key = "tls.key"; path = "key"; }]; };
#
#   # Single container — auto-inject:
#   deployment = { ... }
#     |> kix.withMounts [ self.libraryMount self.configMount ]
#     |> scope.mkDeployment;
#
#   # Multi-container — target a specific container:
#   deployment = { ... }
#     |> kix.withMountsOn "registry" [ self.dataMount ]
#     |> scope.mkDeployment;

{ lib }:

rec {

  # Shorthand for container port declaration.
  # Usage: port "http" 2283           → { name = "http"; containerPort = 2283; }
  #        port "dns" 53 // { protocol = "UDP"; }
  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  # Convert an attrset of env vars to the K8s [{ name, value }] list format.
  # Null values are filtered, so lib.optionalAttrs works naturally for conditionals.
  mkEnvVars =
    attrs:
    lib.mapAttrsToList (name: value: { inherit name value; }) (lib.filterAttrs (_: v: v != null) attrs);

  # Combine named env vars with raw K8s env entries (e.g. valueFrom.secretKeyRef).
  # Usage: mkEnv { KEY = "value"; } [ { name = "SECRET"; valueFrom.secretKeyRef = { name = "my-secret"; key = "password"; }; } ]
  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  # Parse a K8s resource quantity string to GiB (as a number).
  # Supports Ti, Gi, Mi suffixes. Returns null for unrecognized formats.
  # Strips Nix string context so it works on out.* values.
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

  # --- Service helpers ---

  service = {
    # Extract service-compatible port entries from a workload resource.
    # Reads spec.template.spec.containers[*].ports from the workload's rawManifest.
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

    # Create a Service attrset from a workload resource (Deployment, StatefulSet, DaemonSet).
    #
    # Auto-derives:
    #   - spec.selector from workload.out.selector
    #   - spec.ports from workload container ports (override with `ports`)
    #   - outputs.port from first container port
    #
    # Consumed config: name, type, ports
    # Passthrough to mkResource: outputs, requires, labels, annotations, extra, etc.
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

        # Validate that every string targetPort on the final Service.spec.ports
        # list resolves to a named container port declared on the workload.
        # Only user-supplied `ports` can get this wrong — the auto-extracted
        # ports are trivially consistent because they're derived from the
        # container ports themselves.
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

  # --- Ingress helpers ---

  ingress = {
    # Create an Ingress attrset from a service resource.
    #
    # Auto-derives:
    #   - backend service name from service.out.name
    #   - backend port from service.out.port (override with `port`)
    #
    # Consumed config: name, host, path, pathType, port, className, tls
    # Passthrough to mkResource: annotations, labels, requires, extra, etc.
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
        servicePort =
          if port != null then
            port
          else if svc ? out.port then
            builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
          else
            throw "ingress.fromService: service '${svc.name or "unknown"}' has no out.port — specify port explicitly";
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

  # --- HTTPRoute helpers (Gateway API) ---

  httpRoute = {
    # Create an HTTPRoute attrset from a service resource.
    #
    # Auto-derives:
    #   - backend service name from service.out.name
    #   - backend port from service.out.port (override with `port`)
    #
    # Consumed config: name, host, parentRef, path, pathType, port
    # Passthrough to mkResource: annotations, labels, requires, extra, etc.
    fromService =
      {
        name,
        host,
        parentRef, # { name, namespace? } — reference to the Gateway
        path ? "/",
        pathType ? "PathPrefix",
        port ? null,
        ...
      }@cfg:
      svc:
      let
        servicePort =
          if port != null then
            port
          else if svc ? out.port then
            builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
          else
            throw "httpRoute.fromService: service '${svc.name or "unknown"}' has no out.port — specify port explicitly";
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

  # --- Mount helpers ---
  # Typed constructors for volume mounts. Each returns a mount object
  # ({ _type, name, mountPath, source }) or null if the resource is null.
  # Name auto-derives from the resource's out.name.
  #
  # Every mount source carries a `_kix.namespace` marker (extracted from the
  # referenced resource's namespace). `_injectMounts` spreads `m.source` at
  # the volume top level, so the marker lands as a sibling of
  # `configMap` / `persistentVolumeClaim` / `secret` at the volume level.
  # checkNamespacedRefs in scope.nix reads it to enforce same-namespace
  # mounts at build time; stripKixMeta in mkResource removes it before
  # serialization.

  # Extract the home namespace of a k8s-resource. Returns null for
  # cluster-scoped resources or if the resource attrset doesn't carry a
  # namespace handle. Used to stamp `_kix.namespace` on mount sources.
  _resourceNs =
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

  mount = {
    # PersistentVolumeClaim mount.
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
        let
          ns = _resourceNs resource;
        in
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = {
            persistentVolumeClaim.claimName = resource.out.name;
          }
          // lib.optionalAttrs (ns != null) {
            _kix = {
              namespace = ns;
              source = "pvc";
            };
          };
        };

    # ConfigMap mount.
    # items: optional list of { key, path } to select specific keys.
    # defaultMode: optional integer (e.g. 493 for 0755).
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
        let
          ns = _resourceNs resource;
        in
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath;
          ${if subPath != null then "subPath" else null} = subPath;
          source = {
            configMap = {
              name = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          }
          // lib.optionalAttrs (ns != null) {
            _kix = {
              namespace = ns;
              source = "configMap";
            };
          };
        };

    # Secret mount.
    # items: optional list of { key, path } to select specific keys.
    # defaultMode: optional integer.
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
        let
          ns = _resourceNs resource;
        in
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath;
          ${if subPath != null then "subPath" else null} = subPath;
          source = {
            secret = {
              secretName = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          }
          // lib.optionalAttrs (ns != null) {
            _kix = {
              namespace = ns;
              source = "secret";
            };
          };
        };

    # EmptyDir mount (no resource — name is required).
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
  };

  # Shared implementation for mount injection.
  _injectMounts =
    targetName: mounts: attrs:
    let
      validMounts = builtins.filter (m: m != null) mounts;
      volumes = map (m: { inherit (m) name; } // m.source) validMounts;

      # Guard against silent volume-name collisions. A collision here means
      # the K8s API server drops one volume definition, causing a subtle
      # runtime failure (mount points at the wrong source). Catch at eval.
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

  # Inject mounts into a single-container pod (pre-seal).
  # Nulls in the mount list are filtered. Errors on multi-container pods.
  withMounts = _injectMounts null;

  # Inject mounts into a specific container by name (pre-seal).
  # Usage: { ... } |> kix.withMountsOn "registry" [ ... ] |> scope.mkDeployment;
  withMountsOn = containerName: _injectMounts containerName;

  # --- Escape hatch for untracked references ---

  # Explicit escape hatch for secret/resource names not managed by kix.
  # Use when referencing resources created outside kix (Helm hooks, cert-manager,
  # ESO, bootstrap secrets, etc.). Makes the untracked reference visible and
  # auditable rather than silently allowing raw strings.
  #
  # Usage: secretName = kix.untrackedRef "ingress-nginx-admission";
  #
  # This bypasses the DI-tracking check in mkDeployment/mkStatefulSet/mkDaemonSet.
  # Raw string literals without untrackedRef are a compile error.
  untrackedRef =
    name:
    let
      marker = builtins.toFile "kix-untracked-ref" name;
    in
    builtins.appendContext name (builtins.getContext "${marker}");

  # --- Shared option definitions ---

  options = {
    # Standard ingress options. Packages use: options.ingress = kix.options.ingress;
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

    # Standard monitoring options. Packages use: options.metrics = kix.options.monitor;
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

  # --- Exposure build entry ---
  #
  # Returns a build entry function that creates an Ingress or HTTPRoute
  # resource, depending on which DI dep is present:
  #   - gateway → HTTPRoute (Gateway API). TLS is the Gateway's concern.
  #   - ingressNginx → Ingress (legacy). TLS via clusterIssuer.
  #
  # The app developer adds this to their build list and never touches
  # infrastructure deps directly.
  #
  # Usage:
  #   build = [
  #     ({ self, config, scope, kix, myDep, ... }: { ... app logic ... })
  #     (kix.expose { service = "service"; })
  #   ];
  #
  # The returned build entry declares gateway, ingressNginx, and clusterIssuer
  # as optional DI deps via function args — they're discovered automatically.
  expose =
    {
      service ? null, # string: part name in self to expose (single-backend mode)
      paths ? null, # list of { path, pathType?, service, port? }: multi-backend mode (Ingress only). `service` is the part name in self. Mutually exclusive with `service`.
      partName ? "ingress", # string: name of the generated part in self
      defaultAnnotations ? { }, # attrset: package-level default annotations (Ingress mode only)
      port ? null, # int or null: override auto-derived service port (single-backend mode only)
      tlsSecretName ? null, # string or null: override auto-derived TLS secret name (Ingress mode only)
      tlsSecret ? null, # k8s-resource or null: alternative to tlsSecretName that also enables cross-namespace validation (recommended over tlsSecretName for user-provided certs)
      tlsSecretPart ? null, # string or null: name of a part in `self` whose resource provides the TLS secret. Resolved lazily so callers can wire `self.tlsSecret` (e.g. a `mkSecretRef`) without forward references at package definition.
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

      # Resolve tlsSecret from a part in `self` when `tlsSecretPart` is set.
      # Lazy lookup avoids the chicken-and-egg of passing `self.x` at package
      # definition time (where `self` is not yet bound).
      effectiveTlsSecret = if tlsSecretPart != null then self.${tlsSecretPart} else tlsSecret;

      # Resolve the TLS secret name from the three legal sources and enforce
      # the same-namespace invariant.
      #   1. `tlsSecret = someResource` → resource path, full ns check.
      #   2. `tlsSecretName = someString` → string path, require DI-tracking
      #      (must come from kix.untrackedRef or a tracked secret.out.name).
      #      Ns check only possible if the caller passed it via tlsSecret.
      #   3. Neither set → auto-derived "${name}-tls" in the current scope.
      #
      # K8s ingress controllers only read TLS secrets from the Ingress's own
      # namespace; a mismatch silently serves the default cert instead.
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

      # Gateway API mode: gateway DI dep with out.gatewayRef
      hasGateway = gateway != null && gateway ? out.gatewayRef;

      # Legacy Ingress mode: ingressNginx DI dep with out.ingressClassName
      hasIngress = ingressNginx != null;

      # Both present → ambiguous, fail early so the cluster operator wires explicitly.
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

      # Multi-backend rules: build http.paths from `paths`, resolving each
      # `service` name against `self` to get out.name + auto-derived port.
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

  # --- Monitoring build entry ---
  #
  # Returns a build entry function that creates ServiceMonitor and optional
  # PrometheusRule resources when prometheus is present in the cluster.
  # The app developer adds this to their build list and never touches
  # monitoring deps directly.
  #
  # Usage:
  #   build = [
  #     ({ self, config, scope, kix, myDep, ... }: { ... app logic ... })
  #     (kix.monitor { service = "service"; port = "metrics"; })
  #   ];
  #
  #   # With alert rules:
  #   (kix.monitor {
  #     service = "service";
  #     port = "metrics";
  #     alerts = {
  #       highErrorRate = {
  #         expr = ''rate(http_requests_total{status=~"5.."}[5m]) > 0.05'';
  #         "for" = "5m";
  #         severity = "warning";
  #         description = "Error rate above 5%";
  #       };
  #     };
  #   })
  #
  # The returned build entry declares prometheus as an optional DI dep via
  # function args — it's discovered automatically by discoverBuildDeps.
  monitor =
    {
      service, # string: part name in self to monitor (e.g. "service")
      port ? "metrics", # string or int: port name or number on the service
      path ? "/metrics", # string: scrape path
      alerts ? { }, # attrset: alert name -> { expr, for?, severity, description? }
      extraEndpoints ? [ ], # list: additional scrape endpoints
      extraLabels ? { }, # attrset: additional labels on ServiceMonitor/PrometheusRule
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

      # Build ServiceMonitor endpoints
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

      # Build PrometheusRule groups from the alerts attrset
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
