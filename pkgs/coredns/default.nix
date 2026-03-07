# CoreDNS kix module — migrated from the coredns Helm chart (v1.45.0, appVersion 1.13.1)
#
# Source Helm chart stored at: charts/coredns/ for reference and parity testing.
#
# This module produces the following Kubernetes resources (matching Helm defaults):
#   - ServiceAccount
#   - ClusterRole
#   - ClusterRoleBinding
#   - ConfigMap (Corefile + zone files)
#   - Deployment
#   - Service
#
# Optional resources (behind enable flags, not yet implemented):
#   - HPA, PDB, autoscaler deployment
# ServiceMonitor is handled via Level 3 monitoring.targets (see config section).
#
# Key differences from the original kix/corednsNew module:
#   - One manifest entry per resource (not a single bundled derivation)
#   - Human-readable resource names (not store paths)
#   - Explicit selectorLabels separate from metadata labels
#   - Ports specified explicitly on the Service (not auto-derived)
#   - Fixed: readinessProbe no longer accidentally reads livenessProbe config
#   - Fixed: dnsPolicy uses `if` not `lib.optionalAttrs` (which expects an attrset)

{
  lib,
  pkgs,
  config,
  kixlib,
  ...
}:

let
  types = lib.types;
  cfg = config.services.coredns;

  # Extracted: used in registry, monitoring target, and potentially elsewhere.
  hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) cfg.servers;

  # --- Options ---

  options.services.coredns = {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable CoreDNS service.";
    };

    namespace = lib.mkOption {
      type = types.str;
      default = "default";
      description = "Kubernetes namespace for all CoreDNS resources.";
    };

    clusterDomain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = "Kubernetes cluster domain for DNS resolution.";
    };

    isClusterService = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Whether to label this as a cluster service (adds k8s-app, kubernetes.io/cluster-service labels).";
    };

    replicaCount = lib.mkOption {
      type = types.int;
      default = 1;
      description = "Number of CoreDNS replicas.";
    };

    image = lib.mkOption {
      type = types.submodule {
        options = {
          repository = lib.mkOption { type = types.str; default = "coredns/coredns"; };
          tag = lib.mkOption { type = types.str; default = "1.13.1"; };
          pullPolicy = lib.mkOption { type = types.str; default = "IfNotPresent"; };
        };
      };
      default = { };
      description = "Container image configuration.";
    };

    resources = lib.mkOption {
      type = types.submodule {
        options = {
          limits = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
          requests = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
        };
      };
      default = { };
      description = "CPU/memory requests and limits.";
    };

    serviceAccount = lib.mkOption {
      type = types.submodule {
        options = {
          create = lib.mkOption { type = types.bool; default = false; description = "Create a ServiceAccount. Helm default is false."; };
        };
      };
      default = { };
    };

    serviceType = lib.mkOption {
      type = types.str;
      default = "ClusterIP";
      description = "Service type (ClusterIP, NodePort, LoadBalancer).";
    };

    # Server blocks — the core of CoreDNS config. Matches Helm values.servers structure.
    servers = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          port = lib.mkOption { type = types.int; default = 53; };
          zones = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                zone = lib.mkOption { type = types.str; default = "."; };
                scheme = lib.mkOption { type = types.nullOr types.str; default = null; };
                use_tcp = lib.mkOption { type = types.bool; default = false; };
              };
            });
            default = [{ zone = "."; }];
          };
          plugins = lib.mkOption {
            type = types.listOf (types.submodule {
              options = {
                name = lib.mkOption { type = types.str; };
                parameters = lib.mkOption { type = types.nullOr types.str; default = null; };
                configBlock = lib.mkOption { type = types.nullOr types.str; default = null; };
              };
            });
            default = [];
          };
        };
      });
      # Default matches Helm chart's values.yaml
      default = [{
        zones = [{ zone = "."; use_tcp = true; }];
        port = 53;
        plugins = [
          { name = "errors"; }
          { name = "health"; configBlock = "lameduck 10s"; }
          { name = "ready"; }
          { name = "kubernetes"; parameters = "cluster.local in-addr.arpa ip6.arpa"; configBlock = "pods insecure\nfallthrough in-addr.arpa ip6.arpa\nttl 30"; }
          { name = "prometheus"; parameters = "0.0.0.0:9153"; }
          { name = "forward"; parameters = ". /etc/resolv.conf"; }
          { name = "cache"; parameters = "30"; }
          { name = "loop"; }
          { name = "reload"; }
          { name = "loadbalance"; }
        ];
      }];
    };

    zoneFiles = lib.mkOption {
      type = types.listOf (types.submodule {
        options = {
          filename = lib.mkOption { type = types.str; };
          domain = lib.mkOption { type = types.str; };
          contents = lib.mkOption { type = types.str; };
        };
      });
      default = [];
      description = "Custom zone files to include in the ConfigMap.";
    };

    securityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        allowPrivilegeEscalation = false;
        capabilities = { add = ["NET_BIND_SERVICE"]; drop = ["ALL"]; };
        readOnlyRootFilesystem = true;
      };
      description = "Container security context. Matches Helm defaults.";
    };

    livenessProbe = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          initialDelaySeconds = lib.mkOption { type = types.int; default = 60; };
          periodSeconds = lib.mkOption { type = types.int; default = 10; };
          timeoutSeconds = lib.mkOption { type = types.int; default = 5; };
          failureThreshold = lib.mkOption { type = types.int; default = 5; };
          successThreshold = lib.mkOption { type = types.int; default = 1; };
        };
      };
      default = { };
    };

    readinessProbe = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          initialDelaySeconds = lib.mkOption { type = types.int; default = 30; };
          periodSeconds = lib.mkOption { type = types.int; default = 5; };
          timeoutSeconds = lib.mkOption { type = types.int; default = 5; };
          failureThreshold = lib.mkOption { type = types.int; default = 1; };
          successThreshold = lib.mkOption { type = types.int; default = 1; };
        };
      };
      default = { };
    };
  };

  # --- Corefile builder ---
  # Generates the CoreDNS configuration file from the servers option.
  # Mirrors the Helm chart's configmap.yaml template logic.

  buildCorefile = let
    inherit (lib) concatStringsSep optionalString concatMapStrings splitString;

    renderZone = zone: (if zone.scheme != null then zone.scheme else "") + zone.zone;
    renderZones = zones: if zones == [] then "." else concatStringsSep " " (map renderZone zones);

    renderPlugin = plugin: let
      params = optionalString (plugin.parameters != null) (" " + plugin.parameters);
      block = optionalString (plugin.configBlock != null) (
        " {\n" + concatMapStrings (line: "        " + line + "\n") (splitString "\n" plugin.configBlock) + "    }"
      );
    in "    " + plugin.name + params + block + "\n";

    renderServer = server: let
      zones = renderZones server.zones;
      port = optionalString (server.port != null) (":" + toString server.port);
      plugins = concatStringsSep "" (map renderPlugin server.plugins);
    # No trailing newline — concatStringsSep handles separation between servers,
    # and we don't want an extra newline at the end (Helm doesn't produce one).
    in zones + port + " {\n" + plugins + "}";

  in concatStringsSep "\n" (map renderServer cfg.servers);

  # --- Port derivation ---
  # Derives service/container ports from server blocks, matching the Helm
  # chart's _helpers.tpl coredns.servicePorts / coredns.containerPorts logic.

  # Port derivation mirrors the Helm chart's _helpers.tpl logic, but with one
  # important distinction: Helm has SEPARATE helpers for servicePorts and
  # containerPorts. servicePorts only derives from server block zones (the ports
  # users connect to). containerPorts ALSO includes plugin ports like prometheus
  # (9153). This makes sense — prometheus metrics are exposed on the container
  # but shouldn't be in the Service (users don't query metrics via the DNS Service).
  derivePorts = let
    inherit (lib) flatten concatMap groupBy mapAttrs any optional;

    # Determine protocols for a zone. Note: zone.scheme comes from the module
    # system so it's explicitly null (not absent). We must use `if` rather than
    # `or` — `zone.scheme or "dns://"` returns null when scheme exists but is null,
    # because `or` only provides a default for *missing* keys, not null values.
    zoneToProtocol = server: zone: let
      scheme = if zone.scheme != null then zone.scheme else "";
    in {
      port = toString server.port;
      istcp = (zone.use_tcp or false) || (builtins.elem scheme ["tls://" "grpc://" "https://"]);
      isudp = builtins.elem scheme ["dns://" ""];
    };

    # Plugin ports (e.g., prometheus) — only for containerPorts, NOT servicePorts.
    pluginToProtocol = plugin:
      if plugin.name == "prometheus" && plugin.parameters != null then
        let port = lib.last (lib.splitString ":" (toString plugin.parameters));
        in [{ inherit port; istcp = true; isudp = false; }]
      else [];

    # Zone-derived ports (for both service and container)
    zoneReqs = concatMap (server: map (zoneToProtocol server) server.zones) cfg.servers;
    zoneGrouped = groupBy (r: r.port) zoneReqs;

    # All ports including plugins (for container only)
    allReqs = zoneReqs ++ concatMap (server: concatMap pluginToProtocol server.plugins) cfg.servers;
    allGrouped = groupBy (r: r.port) allReqs;

    mergeProtocols = port: reqs: {
      inherit port;
      istcp = any (r: r.istcp) reqs;
      isudp = any (r: r.isudp) reqs || (!any (r: r.istcp) reqs && !any (r: r.isudp) reqs);
    };

    zoneMerged = mapAttrs mergeProtocols zoneGrouped;
    allMerged = mapAttrs mergeProtocols allGrouped;

    toServicePorts = portConfig:
      (optional portConfig.isudp {
        port = lib.toInt portConfig.port;
        targetPort = lib.toInt portConfig.port;
        protocol = "UDP";
        name = "udp-${portConfig.port}";
      }) ++
      (optional portConfig.istcp {
        port = lib.toInt portConfig.port;
        targetPort = lib.toInt portConfig.port;
        protocol = "TCP";
        name = "tcp-${portConfig.port}";
      });

    toContainerPorts = portConfig:
      (optional portConfig.isudp {
        containerPort = lib.toInt portConfig.port;
        protocol = "UDP";
        name = "udp-${portConfig.port}";
      }) ++
      (optional portConfig.istcp {
        containerPort = lib.toInt portConfig.port;
        protocol = "TCP";
        name = "tcp-${portConfig.port}";
      });

  in {
    # servicePorts: only zone-derived ports (not plugin ports like prometheus)
    servicePorts = flatten (map toServicePorts (builtins.attrValues zoneMerged));
    # containerPorts: all ports including plugins
    containerPorts = flatten (map toContainerPorts (builtins.attrValues allMerged));
  };

  ports = derivePorts;

  # --- Labels ---
  # Stable selector labels — NEVER include version here (breaks rolling updates).
  # releaseName comes from cluster.releaseName (Level 1 intent merging) via
  # mkDefault in the config section below. Defaults to "release-name" for
  # Helm parity, but cluster-wide config can change it for all charts at once.
  selectorLabels = {
    "app.kubernetes.io/instance" = config.cluster.releaseName;
    "app.kubernetes.io/name" = "coredns";
  } // lib.optionalAttrs cfg.isClusterService {
    "k8s-app" = "coredns";
  };

  # Full metadata labels for all resources.
  # cluster.labels (Level 1) are merged as a base — chart-specific labels
  # override them if there's a key collision.
  allLabels = config.cluster.labels // selectorLabels // {
    "app.kubernetes.io/managed-by" = "kix";
  } // lib.optionalAttrs cfg.isClusterService {
    "kubernetes.io/cluster-service" = "true";
    "kubernetes.io/name" = "CoreDNS";
  };

  # --- kixlib setup ---
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = allLabels;
    name = "coredns";
  };

  # --- Resource construction ---

  sa = kixlib'.rbac.mkServiceAccount { };

  clusterRole = kixlib'.rbac.mkClusterRole {
    rules = [
      { apiGroups = [""]; resources = ["endpoints" "services" "pods" "namespaces"]; verbs = ["list" "watch"]; }
      { apiGroups = ["discovery.k8s.io"]; resources = ["endpointslices"]; verbs = ["list" "watch"]; }
    ];
  };

  # The ClusterRoleBinding subject name must match the actual serviceAccountName
  # used by the Deployment. When serviceAccount.create is false, Helm binds to
  # "default" (the K8s default SA), not the chart's SA resource name.
  binding = let
    rawBinding = kixlib'.rbac.mkClusterRoleBinding clusterRole sa;
  in lib.recursiveUpdate rawBinding {
    subjects = [{
      kind = "ServiceAccount";
      name = serviceAccountName;
      namespace = cfg.namespace;
    }];
  };

  coreDnsConfigMap = kixlib'.configMap.mkConfigMap { }
    |> kixlib'.configMap.withEntry "Corefile" buildCorefile;

  # Volume name "config-volume" matches the Helm chart's hardcoded name.
  configVolume = coreDnsConfigMap |> kixlib'.configMap.asVolume {
    name = "config-volume";
    items = [{ key = "Corefile"; path = "Corefile"; }]
      ++ map (zf: { key = zf.filename; path = zf.filename; }) cfg.zoneFiles;
  };

  container = kixlib'.pod.mkContainer {
    name = "coredns";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    args = ["-conf" "/etc/coredns/Corefile"];
    resources = cfg.resources;
    ports = ports.containerPorts;
    securityContext = cfg.securityContext;
  }
  |> kixlib'.pod.withVolumeMount {
    name = configVolume.name;
    mountPath = "/etc/coredns";
  }
  |> (c: if cfg.livenessProbe.enabled then kixlib'.pod.withLivenessProbe {
    httpGet = { path = "/health"; port = 8080; scheme = "HTTP"; };
    inherit (cfg.livenessProbe) initialDelaySeconds periodSeconds timeoutSeconds failureThreshold successThreshold;
  } c else c)
  |> (c: if cfg.readinessProbe.enabled then kixlib'.pod.withReadinessProbe {
    httpGet = { path = "/ready"; port = 8181; scheme = "HTTP"; };
    inherit (cfg.readinessProbe) initialDelaySeconds periodSeconds timeoutSeconds failureThreshold successThreshold;
  } c else c);

  # Match Helm's serviceAccountName logic: when serviceAccount.create is true,
  # use the SA's resource name. Otherwise, explicitly set "default" (Helm does
  # this too via its serviceAccountName helper).
  serviceAccountName =
    if cfg.serviceAccount.create then kixlib'.resourceName sa else "default";

  deployment = kixlib'.workload.mkDeployment {
    replicas = cfg.replicaCount;
    selectorLabels = selectorLabels;
    strategy = {
      type = "RollingUpdate";
      rollingUpdate = { maxUnavailable = 1; maxSurge = "25%"; };
    };
    metadata.labels = {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = selectorLabels;
        annotations = lib.optionalAttrs cfg.isClusterService {
          "scheduler.alpha.kubernetes.io/tolerations" =
            ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
        };
      };
      spec = {
        containers = [container];
        volumes = [configVolume];
        terminationGracePeriodSeconds = 30;
        inherit serviceAccountName;
      } // (if cfg.isClusterService then { dnsPolicy = "Default"; } else { });
    };
  };

  service = kixlib'.networking.mkService {
    spec = {
      type = cfg.serviceType;
      ports = ports.servicePorts;
      selector = selectorLabels;
    };
  };

in
{
  inherit options;

  config = {
    # --- Level 1: consume cluster-wide defaults ---
    # mkDefault priority means: cluster default < this < user's explicit setting.
    # When loaded individually (mkChartManifests), cluster.namespace defaults to
    # "default" anyway, so behavior is unchanged for parity testing.
    services.coredns.namespace = lib.mkDefault config.cluster.namespace;
    services.coredns.clusterDomain = lib.mkDefault config.cluster.domain;

    # --- Level 2: service registry ---
    # Advertise our endpoints so other charts/modules can discover coredns
    # without hardcoding DNS names. The prometheus metrics endpoint is only
    # registered if the prometheus plugin is configured in servers.
    registry.coredns = lib.mkIf cfg.enable {
      endpoints = {
        dns-udp = {
          host = "coredns.${cfg.namespace}.svc.${cfg.clusterDomain}";
          port = 53;
          protocol = "dns-udp";
        };
        dns-tcp = {
          host = "coredns.${cfg.namespace}.svc.${cfg.clusterDomain}";
          port = 53;
          protocol = "dns-tcp";
        };
      } // lib.optionalAttrs hasPrometheus {
        metrics = {
          host = "coredns.${cfg.namespace}.svc.${cfg.clusterDomain}";
          port = 9153;
          protocol = "http";
        };
      };
    };

    # --- Level 3: monitoring target ---
    # Declare our metrics endpoint for the cross-cutting monitoring module.
    # Only relevant when prometheus plugin is configured.
    # TODO: CoreDNS doesn't expose a dedicated metrics Service — port 9153 is only
    # on containerPorts (derivePorts excludes plugin ports from servicePorts by design).
    # A proper fix requires creating a separate metrics Service. Disabled until then.
    monitoring.targets.coredns = lib.mkIf (cfg.enable && hasPrometheus) {
      enabled = false;
      serviceName = "coredns";
      namespace = cfg.namespace;
      portName = "tcp-9153";
      selector = selectorLabels;
    };

    # --- Level 3: network policy declaration ---
    networkPolicies.services.coredns = lib.mkIf cfg.enable {
      namespace = cfg.namespace;
      podSelector = selectorLabels;
      ingressPorts = [ 53 ];
      egressTo = [];
    };

    # One manifest entry per resource — this is what verify-parity.sh compares.
    manifests = lib.optionalAttrs cfg.enable ({
      "coredns-deployment" = kixlib'.mkManifest deployment;
      "coredns-configmap" = kixlib'.mkManifest coreDnsConfigMap;
      "coredns-service" = kixlib'.mkManifest service;
      "coredns-clusterrole" = kixlib'.mkManifest clusterRole;
      "coredns-clusterrolebinding" = kixlib'.mkManifest binding;
    } // lib.optionalAttrs cfg.serviceAccount.create {
      "coredns-serviceaccount" = kixlib'.mkManifest sa;
    });
  };
}
