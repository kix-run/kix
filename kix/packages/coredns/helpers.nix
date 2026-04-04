# Corefile generation helpers for CoreDNS.
#
# Builds a Corefile string from structured server block definitions.
# Each server block has zones, a port, and an ordered list of plugins.

{ lib }:

rec {

  # Render a single plugin line.
  # A plugin can be:
  #   - A string: "errors" -> "errors"
  #   - An attrset with `name` and optional `parameters` (string) and `block` (list of strings):
  #     { name = "health"; parameters = ""; block = [ "lameduck 10s" ]; }
  #     -> "health {\n    lameduck 10s\n}"
  renderPlugin =
    indent: plugin:
    if builtins.isString plugin then
      "${indent}${plugin}"
    else
      let
        params = plugin.parameters or "";
        paramStr = if params != "" then " ${params}" else "";
        block = plugin.block or [ ];
      in
      if block == [ ] then
        "${indent}${plugin.name}${paramStr}"
      else
        lib.concatStringsSep "\n" (
          [
            "${indent}${plugin.name}${paramStr} {"
          ]
          ++ (map (line: "${indent}    ${line}") block)
          ++ [
            "${indent}}"
          ]
        );

  # Render a single server block.
  # { zones = [ "." ]; port = "53"; plugins = [ ... ]; }
  renderServerBlock =
    server:
    let
      zones = server.zones or [ "." ];
      port = server.port or "53";
      zoneStr = lib.concatStringsSep " " zones;
      header = "${zoneStr}:${port}";
      pluginLines = map (renderPlugin "    ") (server.plugins or [ ]);
    in
    lib.concatStringsSep "\n" (
      [
        "${header} {"
      ]
      ++ pluginLines
      ++ [
        "}"
      ]
    );

  # Render a snippet definition block.
  # { snippet = "common_plugins"; plugins = [ ... ]; }
  # -> "(common_plugins) {\n    ...\n}"
  renderSnippet =
    block:
    let
      pluginLines = map (renderPlugin "    ") (block.plugins or [ ]);
    in
    lib.concatStringsSep "\n" (
      (lib.optional (block ? comment) "# ${block.comment}")
      ++ [
        "(${block.snippet}) {"
      ]
      ++ pluginLines
      ++ [
        "}"
      ]
    );

  # Render a generic Corefile block — dispatches on shape.
  # - { snippet = ...; } -> snippet definition
  # - { header = ...; } -> raw header server block (e.g. "dns://.:53")
  # - otherwise -> standard server block
  renderBlock =
    block:
    if block ? snippet then
      renderSnippet block
    else if block ? header then
      let
        pluginLines = map (renderPlugin "    ") (block.plugins or [ ]);
      in
      lib.concatStringsSep "\n" (
        (lib.optional (block ? comment) "# ${block.comment}")
        ++ [
          "${block.header} {"
        ]
        ++ pluginLines
        ++ [
          "}"
        ]
      )
    else
      renderServerBlock block;

  # Build a complete Corefile from a list of server/snippet blocks.
  mkCorefile = servers: lib.concatStringsSep "\n" (map renderBlock servers);

  # Default server block matching the upstream Helm chart defaults.
  defaultServer = {
    zones = [ "." ];
    port = "53";
    plugins = [
      "errors"
      {
        name = "health";
        parameters = "";
        block = [ "lameduck 10s" ];
      }
      "ready"
      {
        name = "kubernetes";
        parameters = "cluster.local in-addr.arpa ip6.arpa";
        block = [
          "pods insecure"
          "fallthrough in-addr.arpa ip6.arpa"
          "ttl 30"
        ];
      }
      "prometheus 0.0.0.0:9153"
      "forward . /etc/resolv.conf"
      "cache 30"
      "loop"
      "reload"
      "loadbalance"
    ];
  };
}
