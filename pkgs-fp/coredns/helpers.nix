# CoreDNS package-specific helpers (fixpoint version).
#
# Pure functions for Corefile generation and port derivation. These are
# unchanged from the module-system version — they have no dependency on
# the composition mechanism.

{ lib }:

rec {

  # --- Plugin DSL ---
  # Pipe-composable constructors for CoreDNS server plugins. Without the
  # module system there are no submodule defaults, so every plugin would
  # need explicit `parameters = null; configBlock = null;`. These helpers
  # eliminate that boilerplate:
  #
  #   plugin "errors"
  #   plugin "health"     |> withBlock "lameduck 10s"
  #   plugin "kubernetes" |> withParams "cluster.local" |> withBlock "pods insecure"
  #   plugin "prometheus" |> withParams "0.0.0.0:9153"
  #
  plugin = name: {
    inherit name;
    parameters = null;
    configBlock = null;
  };
  withParams = parameters: p: p // { inherit parameters; };
  withBlock = configBlock: p: p // { inherit configBlock; };

  # --- Corefile builder ---
  # Generates the CoreDNS configuration file from the servers option.
  # Mirrors the Helm chart's configmap.yaml template logic.
  buildCorefile =
    servers:
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
        in
        zones + port + " {\n" + plugins + "}";

    in
    concatStringsSep "\n" (map renderServer servers);

  # --- Port derivation ---
  # Derives service/container ports from server blocks, matching the Helm
  # chart's _helpers.tpl coredns.servicePorts / coredns.containerPorts logic.
  derivePorts =
    servers:
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

      zoneReqs = concatMap (server: map (zoneToProtocol server) server.zones) servers;
      zoneGrouped = groupBy (r: r.port) zoneReqs;
      allReqs = zoneReqs ++ concatMap (server: concatMap pluginToProtocol server.plugins) servers;
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

}
