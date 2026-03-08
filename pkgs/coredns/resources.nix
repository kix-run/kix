# CoreDNS resource construction and config wiring.
#
# This file builds all Kubernetes resources for the CoreDNS module and wires
# them into config.manifests, config.registry, and config.monitoring.
# Option declarations live in options.nix.
#
# Source Helm chart: coredns/coredns (v1.45.0, appVersion 1.13.1)
#
# Resources produced:
#   - ServiceAccount (optional, behind serviceAccount.create)
#   - ClusterRole + ClusterRoleBinding
#   - ConfigMap (Corefile + zone files)
#   - Deployment
#   - Service
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
  cfg = config.services.coredns;

  # Extracted: used in registry, monitoring target, and potentially elsewhere.
  hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) cfg.servers;

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
  selectorLabels = {
    "app.kubernetes.io/instance" = "release-name";
    "app.kubernetes.io/name" = "coredns";
  } // lib.optionalAttrs cfg.isClusterService {
    "k8s-app" = "coredns";
  };

  # Full metadata labels for all resources.
  # cluster.labels are merged as a base — chart-specific labels override on collision.
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
  config = {
    # Consume cluster-wide DNS domain via mkDefault so per-chart override still wins.
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
