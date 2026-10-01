# The Corefile as data: rendering the typed `servers` option, the ports the
# rendered config listens on, and the checks that refuse a Corefile CoreDNS
# would reject or that would leave the pod unprobed. Pure functions of the
# option value; default.nix adds the checks that need the build context.
{ lib }:

let
  # Listen addresses of the plugins the pod spec depends on when their
  # directive has no address argument (CoreDNS plugin docs).
  defaultListen = {
    health = ":8080";
    ready = ":8181";
    prometheus = "localhost:9153";
  };

  loopbackHosts = [
    "localhost"
    "127.0.0.1"
    "[::1]"
  ];

  # Zone names compare without their trailing dot: `cluster.local.` and
  # `cluster.local` are the same zone to CoreDNS.
  normalizeZone = z: if z != "." && lib.hasSuffix "." z then lib.removeSuffix "." z else z;

  enabledServers = servers: lib.filterAttrs (_: s: s.enabled) servers;

  enabledPlugins = server: lib.filterAttrs (_: p: p.enabled) server.plugins;

  # The enabled directives of one server that run plugin `name`, whatever
  # attribute holds them.
  directivesOf =
    name: server: builtins.filter (p: p.name == name) (builtins.attrValues (enabledPlugins server));

  hasView = server: directivesOf "view" server != [ ];

  # Server names in render order. Among blocks that share a zone and port,
  # CoreDNS tries them in Corefile order and the first block whose view
  # matches answers, so blocks with a view come first; the name orders
  # the rest.
  orderedNames =
    servers:
    let
      enabled = enabledServers servers;
      rank = n: if hasView enabled.${n} then 0 else 1;
    in
    lib.sort (a: b: if rank a != rank b then rank a < rank b else a < b) (builtins.attrNames enabled);

  # The port of a listen address: the text after its last `:`.
  listenPort =
    addr:
    let
      parts = lib.splitString ":" addr;
      last = lib.last parts;
    in
    if builtins.length parts < 2 || builtins.match "[0-9]+" last == null then null else lib.toInt last;

  # The host of a listen address: everything before its last `:`.
  listenHost =
    addr:
    let
      parts = lib.splitString ":" addr;
    in
    lib.concatStringsSep ":" (lib.init parts);

  isLoopback = addr: builtins.elem (listenHost addr) loopbackHosts;

  # Every listen address plugin `name` has across the enabled servers, as
  # `{ server; addr; }`.
  listenersOf =
    name: servers:
    builtins.concatMap (
      serverName:
      map (p: {
        server = serverName;
        addr = if p.args != [ ] then builtins.head p.args else defaultListen.${name};
      }) (directivesOf name servers.${serverName})
    ) (orderedNames servers);

  # The one port a plugin listens on, or null when no enabled server runs it.
  # Two different ports are refused by `checks`.
  pluginPort =
    name: servers:
    let
      listeners = listenersOf name servers;
    in
    if listeners == [ ] then null else listenPort (builtins.head listeners).addr;

  renderDirective =
    p:
    let
      head = lib.concatStringsSep " " ([ p.name ] ++ p.args);
    in
    if p.block == [ ] then
      "    ${head}"
    else
      "    ${head} {\n" + lib.concatMapStrings (l: "        ${l}\n") p.block + "    }";

  # Directives in attribute-name order. CoreDNS runs plugins in the order
  # compiled into the binary (plugin.cfg), not the Corefile's, so the order
  # here only matters between repeats of one plugin.
  renderServer =
    server:
    let
      header = lib.concatMapStringsSep " " (z: "${z}:${toString server.port}") server.zones;
      directives = map renderDirective (builtins.attrValues (enabledPlugins server));
    in
    "${header} {\n" + lib.concatMapStrings (d: "${d}\n") directives + "}\n";

  render =
    servers: lib.concatMapStringsSep "\n" (n: renderServer servers.${n}) (orderedNames servers);

  facts = servers: {
    serverPorts = lib.unique (
      lib.sort (a: b: a < b) (map (s: s.port) (builtins.attrValues (enabledServers servers)))
    );
    healthPort = pluginPort "health" servers;
    readyPort = pluginPort "ready" servers;
    metricsPort = pluginPort "prometheus" servers;
  };

  # Error messages for the Corefile; an empty list means it passes. The
  # caller prefixes them with the instance.
  checks =
    { servers, clusterDomain }:
    let
      enabled = enabledServers servers;
      names = orderedNames servers;
      firstServer = if names == [ ] then "default" else builtins.head names;
      domain = normalizeZone clusterDomain;

      noServer = lib.optional (
        enabled == { }
      ) "no server block is enabled. Set servers.default.enabled = true or add a block.";

      servesDomain =
        server:
        builtins.any (
          p:
          let
            zones = if p.args == [ ] then server.zones else p.args;
          in
          builtins.elem domain (map normalizeZone zones)
        ) (directivesOf "kubernetes" server);

      noClusterDomain =
        lib.optional (enabled != { } && !builtins.any servesDomain (builtins.attrValues enabled))
          "no server block runs the kubernetes plugin for the cluster domain '${domain}', so Service names would not resolve. Set servers.${firstServer}.plugins.kubernetes.enabled = true with '${domain}' in its args.";

      probeTargets = [
        {
          plugin = "health";
          probe = "liveness";
        }
        {
          plugin = "ready";
          probe = "readiness";
        }
      ];
      missingProbeTargets = lib.optionals (enabled != { }) (
        map (
          t:
          "no server block enables the ${t.plugin} plugin; the ${t.probe} probe calls it. Set servers.${firstServer}.plugins.${t.plugin}.enabled = true."
        ) (builtins.filter (t: listenersOf t.plugin servers == [ ]) probeTargets)
      );

      listenerChecks =
        plugin:
        let
          listeners = listenersOf plugin servers;
          loopback = map (
            l:
            "the ${plugin} plugin listens on ${l.addr}, which the kubelet (or Prometheus) cannot reach from outside the pod. Set servers.${l.server}.plugins.${plugin}.args = [ \":${
              toString (
                if listenPort l.addr != null then listenPort l.addr else listenPort defaultListen.${plugin}
              )
            }\" ]."
          ) (builtins.filter (l: isLoopback l.addr) listeners);
          unparsable = map (
            l:
            "the ${plugin} plugin's address '${l.addr}' in servers.${l.server} has no port. Write it as \":<port>\"."
          ) (builtins.filter (l: listenPort l.addr == null) listeners);
          byPort = lib.groupBy (l: toString (listenPort l.addr)) (
            builtins.filter (l: listenPort l.addr != null) listeners
          );
          conflicting =
            lib.optional (builtins.length (builtins.attrNames byPort) > 1)
              "the ${plugin} plugin listens on different ports in ${
                lib.concatMapStringsSep " and " (l: "servers.${l.server} (${l.addr})") (
                  map builtins.head (builtins.attrValues byPort)
                )
              }; the pod exposes one. Give every block the same address.";
        in
        loopback ++ unparsable ++ conflicting;

      # Blocks sharing a zone and port, by "zone:port".
      byZonePort = lib.groupBy (e: e.key) (
        builtins.concatMap (
          n:
          map (z: {
            key = "${normalizeZone z}:${toString enabled.${n}.port}";
            server = n;
          }) enabled.${n}.zones
        ) names
      );
      duplicateZones = lib.concatLists (
        lib.mapAttrsToList (
          key: entries:
          let
            viewless = lib.unique (builtins.filter (n: !hasView enabled.${n}) (map (e: e.server) entries));
          in
          lib.optional (builtins.length viewless > 1)
            "servers ${lib.concatStringsSep " and " viewless} both serve ${key} without a view plugin; CoreDNS refuses to start (duplicate zone). To replace the default block, set servers.default.enabled = false; otherwise give every block but one a view, or merge them."
        ) byZonePort
      );
      repeatedViews = map (
        n: "servers.${n} has more than one enabled view plugin; CoreDNS accepts one per block."
      ) (builtins.filter (n: builtins.length (directivesOf "view" enabled.${n}) > 1) names);
    in
    noServer
    ++ noClusterDomain
    ++ missingProbeTargets
    ++ builtins.concatMap listenerChecks [
      "health"
      "ready"
      "prometheus"
    ]
    ++ duplicateZones
    ++ repeatedViews;
in
{
  inherit
    render
    listenPort
    isLoopback
    facts
    checks
    directivesOf
    enabledServers
    ;
}
