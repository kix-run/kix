# CoreDNS package-specific helpers.
#
# Contains: Corefile builder, port derivation, label construction, FQDN helpers.
# These are domain-specific utilities that don't belong in kixlib but are too
# large to inline in resources.nix.

{
  lib,
  config,
  kixlib,
  cfg,
  labels,
  ...
}:

let
  # Extracted: used in registry, monitoring target, and potentially elsewhere.
  hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) cfg.servers;

  # --- Corefile builder ---
  # Generates the CoreDNS configuration file from the servers option.
  # Mirrors the Helm chart's configmap.yaml template logic.
  buildCorefile =
    let
      inherit (lib)
        concatStringsSep
        optionalString
        concatMapStrings
        splitString
        ;

      renderZone = zone: (if zone.scheme != null then zone.scheme else "") + zone.zone;
      renderZones = zones: if zones == [ ] then "." else concatStringsSep " " (map renderZone zones);

      renderPlugin =
        plugin:
        let
          params = optionalString (plugin.parameters != null) (" " + plugin.parameters);
          block = optionalString (plugin.configBlock != null) (
            " {\n"
            + concatMapStrings (line: "        " + line + "\n") (splitString "\n" plugin.configBlock)
            + "    }"
          );
        in
        "    " + plugin.name + params + block + "\n";

      renderServer =
        server:
        let
          zones = renderZones server.zones;
          port = optionalString (server.port != null) (":" + toString server.port);
          plugins = concatStringsSep "" (map renderPlugin server.plugins);
          # No trailing newline — concatStringsSep handles separation between servers,
          # and we don't want an extra newline at the end (Helm doesn't produce one).
        in
        zones + port + " {\n" + plugins + "}";

    in
    concatStringsSep "\n" (map renderServer cfg.servers);

  # --- Port derivation ---
  # Derives service/container ports from server blocks, matching the Helm
  # chart's _helpers.tpl coredns.servicePorts / coredns.containerPorts logic.
  ports =
    let
      inherit (lib)
        flatten
        concatMap
        groupBy
        mapAttrs
        any
        optional
        ;

      zoneToProtocol =
        server: zone:
        let
          scheme = if zone.scheme != null then zone.scheme else "";
        in
        {
          port = toString server.port;
          istcp =
            (zone.use_tcp or false)
            || (builtins.elem scheme [
              "tls://"
              "grpc://"
              "https://"
            ]);
          isudp = builtins.elem scheme [
            "dns://"
            ""
          ];
        };

      pluginToProtocol =
        plugin:
        if plugin.name == "prometheus" && plugin.parameters != null then
          let
            port = lib.last (lib.splitString ":" (toString plugin.parameters));
          in
          [
            {
              inherit port;
              istcp = true;
              isudp = false;
            }
          ]
        else
          [ ];

      zoneReqs = concatMap (server: map (zoneToProtocol server) server.zones) cfg.servers;
      zoneGrouped = groupBy (r: r.port) zoneReqs;
      allReqs = zoneReqs ++ concatMap (server: concatMap pluginToProtocol server.plugins) cfg.servers;
      allGrouped = groupBy (r: r.port) allReqs;

      mergeProtocols = port: reqs: {
        inherit port;
        istcp = any (r: r.istcp) reqs;
        isudp = any (r: r.isudp) reqs || (!any (r: r.istcp) reqs && !any (r: r.isudp) reqs);
      };

      zoneMerged = mapAttrs mergeProtocols zoneGrouped;
      allMerged = mapAttrs mergeProtocols allGrouped;

      toServicePorts =
        portConfig:
        (optional portConfig.isudp {
          port = lib.toInt portConfig.port;
          targetPort = lib.toInt portConfig.port;
          protocol = "UDP";
          name = "udp-${portConfig.port}";
        })
        ++ (optional portConfig.istcp {
          port = lib.toInt portConfig.port;
          targetPort = lib.toInt portConfig.port;
          protocol = "TCP";
          name = "tcp-${portConfig.port}";
        });

      toContainerPorts =
        portConfig:
        (optional portConfig.isudp {
          containerPort = lib.toInt portConfig.port;
          protocol = "UDP";
          name = "udp-${portConfig.port}";
        })
        ++ (optional portConfig.istcp {
          containerPort = lib.toInt portConfig.port;
          protocol = "TCP";
          name = "tcp-${portConfig.port}";
        });

    in
    {
      servicePorts = flatten (map toServicePorts (builtins.attrValues zoneMerged));
      containerPorts = flatten (map toContainerPorts (builtins.attrValues allMerged));
    };

  # --- Labels ---
  # CoreDNS adds cluster-service labels as extras and a coredns-specific
  # "k8s-app" selector label when isClusterService is true.
  # We extend the labels provided by mkChartModule.
  selectorLabels =
    labels.selector
    // lib.optionalAttrs cfg.isClusterService {
      "k8s-app" = "coredns";
    };

  allLabels =
    labels.all
    // lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
      "k8s-app" = "coredns";
    };

  # Override kixlib' to use coredns-specific labels (with cluster-service extras).
  kixlibCoredns = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = allLabels;
    name = "coredns";
  };

  # FQDN used in registry endpoints.
  corednsFqdn = kixlib.mkFqdn {
    name = "coredns";
    namespace = cfg.namespace;
    clusterDomain = cfg.clusterDomain;
  };

  # Capability output labels for the metrics Service.
  # Guard MUST match the mkIf on capabilities.monitoring.coredns declaration
  # in resources.nix. If the guard drifts from the target declaration, the chart
  # crashes when monitoring is disabled (attribute-missing on a non-existent
  # target). See doc 12 rule #10.
  monitoringGuard = hasPrometheus && cfg.prometheus.service.enabled && cfg.prometheus.monitor.enabled;

  monitoringLabels =
    if monitoringGuard then config.capabilities.monitoring.coredns.output.labels else { };
  monitoringAnnotations =
    if monitoringGuard then config.capabilities.monitoring.coredns.output.annotations else { };

  pdbEnabled =
    cfg.podDisruptionBudget.minAvailable != null || cfg.podDisruptionBudget.maxUnavailable != null;

in
{
  inherit
    hasPrometheus
    buildCorefile
    ports
    selectorLabels
    allLabels
    kixlibCoredns
    corednsFqdn
    monitoringGuard
    monitoringLabels
    monitoringAnnotations
    pdbEnabled
    ;
}
