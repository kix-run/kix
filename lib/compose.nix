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
      in
      {
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

  # --- Mount helpers ---
  # Typed constructors for volume mounts. Each returns a mount object
  # ({ _type, name, mountPath, source }) or null if the resource is null.
  # Name auto-derives from the resource's out.name.

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
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source.persistentVolumeClaim.claimName = resource.out.name;
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
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath;
          ${if subPath != null then "subPath" else null} = subPath;
          source.configMap = {
            name = resource.out.name;
          }
          // lib.optionalAttrs (items != null) { inherit items; }
          // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
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
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath;
          ${if subPath != null then "subPath" else null} = subPath;
          source.secret = {
            secretName = resource.out.name;
          }
          // lib.optionalAttrs (items != null) { inherit items; }
          // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
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
    attrs
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
  # Returns a build entry function that creates an Ingress resource when
  # ingressNginx is present in the cluster, with auto-TLS when clusterIssuer
  # is present. The app developer adds this to their build list and never
  # touches infrastructure deps directly.
  #
  # Usage:
  #   build = [
  #     ({ self, config, scope, kix, myDep, ... }: { ... app logic ... })
  #     (kix.expose { service = "service"; })
  #   ];
  #
  # The returned build entry declares ingressNginx and clusterIssuer as
  # optional DI deps via function args — they're discovered automatically.
  expose =
    {
      service, # string: part name in self to expose (e.g. "service")
      partName ? "ingress", # string: name of the generated part in self
      defaultAnnotations ? { }, # attrset: package-level default annotations
      port ? null, # int or null: override auto-derived service port
      tlsSecretName ? null, # string or null: override auto-derived TLS secret name
    }:
    {
      self,
      config,
      clusterConfig,
      scope,
      lib,
      ingressNginx ? null,
      clusterIssuer ? null,
      ...
    }:
    let
      svc = self.${service};
      name = scope.instanceName;

      clusterDomain = clusterConfig.cluster.domain or null;
      configHost = (config.ingress or { }).host or null;
      effectiveHost =
        if configHost != null then
          configHost
        else if clusterDomain != null then
          "${name}.${clusterDomain}"
        else
          null;

      hasIngress = ingressNginx != null && effectiveHost != null;
      hasTls = hasIngress && clusterIssuer != null;

      configAnnotations = (config.ingress or { }).annotations or { };
    in
    {
      ${partName} =
        if hasIngress then
          svc
          |> ingress.fromService (
            {
              inherit name;
              host = effectiveHost;
              className = ingressNginx.out.ingressClassName;
              tls = lib.optional hasTls {
                hosts = [ effectiveHost ];
                secretName = if tlsSecretName != null then tlsSecretName else "${name}-tls";
              };
              annotations = defaultAnnotations // configAnnotations;
            }
            // lib.optionalAttrs (port != null) { inherit port; }
          )
          |> (if hasTls then clusterIssuer.out.withCert else lib.id)
          |> scope.mkResource
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
