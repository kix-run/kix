# The nats.conf keys that `settings` may not set, with the reason for each.
#
# Each entry is one setting as server/opts.go reads it at v2.15.3, with
# every spelling its parser accepts (the `case` lines of
# processConfigFileLine, parseCluster, and parseJetStream). An entry with
# `set` is a key the package writes, and one with `unsupported` is a feature
# the package does not support; every spelling of either is refused. An
# entry with neither is a key the user may set, under its first spelling
# only, so that two spellings of one key never meet in one config, where Go's
# map order would pick the winner at each start.
#
# The server lowers each key before matching it, so the package refuses
# keys that are not lower case in the blocks it checks, and then matches
# names exactly.
{ lib }:

let
  topEntries = ports: [
    {
      keys = [ "port" ];
      set = "Clients connect on port ${toString ports.client} so the client Service, health check, and `out.port` match.";
    }
    {
      keys = [ "listen" ];
      set = "Clients connect on port ${toString ports.client} so the client Service, health check, and `out.port` match.";
    }
    {
      keys = [
        "host"
        "net"
      ];
      set = "`nats-server` must listen on all network interfaces so Kubernetes Services and pod probes can reach it.";
    }
    {
      keys = [ "client_advertise" ];
      set = "Clients connect through the client Service, so pods do not advertise individual pod addresses.";
    }
    {
      keys = [
        "http_port"
        "monitor_port"
      ];
      set = "Pod probes, the headless Service (`out.monitoringHost`), and the metrics exporter all use port ${toString ports.monitor}.";
    }
    {
      keys = [ "http" ];
      set = "Pod probes, the headless Service (`out.monitoringHost`), and the metrics exporter all use port ${toString ports.monitor}.";
    }
    {
      keys = [
        "https"
        "https_port"
      ];
      set = "Pod probes and the metrics exporter read the monitoring endpoint over plain HTTP on port ${toString ports.monitor}.";
    }
    {
      keys = [ "http_base_path" ];
      set = "Pod probes request `/healthz` at the root path `/`.";
    }
    {
      keys = [ "server_name" ];
      set = "Each server is named after its pod so JetStream keeps the same peer identity across restarts.";
    }
    {
      keys = [
        "pid_file"
        "pidfile"
      ];
      set = "The `preStop` hook reads `/var/run/nats/nats.pid` to drain client connections before shutdown.";
    }
    {
      keys = [ "lame_duck_duration" ];
      set = "On shutdown, `nats-server` waits 10 seconds and drains clients within a 30-second lame duck window that fits inside the pod's 60-second termination grace period.";
    }
    {
      keys = [ "lame_duck_grace_period" ];
      set = "On shutdown, `nats-server` waits 10 seconds and drains clients within a 30-second lame duck window that fits inside the pod's 60-second termination grace period.";
    }
    {
      keys = [
        "store_dir"
        "storedir"
      ];
      set = "JetStream stores its files on the volume mounted at `/data`.";
      instead = "Set `storage.size` or `storage.storageClassName` on the instance to configure that volume.";
    }
    {
      keys = [
        "logfile"
        "log_file"
      ];
      set = "The container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [
        "logfile_size_limit"
        "log_size_limit"
      ];
      set = "The container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [
        "logfile_max_num"
        "log_max_num"
      ];
      set = "The container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [ "syslog" ];
      set = "`nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [ "remote_syslog" ];
      unsupported = "Generated network policies do not allow outbound traffic to a syslog server, and `nats-server` logs to standard output.";
    }
    {
      keys = [ "ports_file_dir" ];
      set = "The container's root filesystem is read-only, and Kubernetes Services expose the server's fixed ports.";
    }
    {
      keys = [ "prof_port" ];
      unsupported = "No Service or network policy exposes the Go profiling port.";
    }
    {
      keys = [ "tls" ];
      unsupported = "Clients and the post-deploy health check connect over plain `nats://` (`out.url`).";
    }
    {
      keys = [ "allow_non_tls" ];
      unsupported = "Clients and the post-deploy health check connect over plain `nats://` (`out.url`).";
    }
    {
      keys = [ "authorization" ];
      set = "Client login comes from the `natsAuth` secret dependency.";
      instead = "Set `username` and `password` in the `natsAuth` secret, or point `deps.natsAuth` at another secret.";
    }
    {
      keys = [ "no_auth_user" ];
      set = "Client login comes from the `natsAuth` secret dependency.";
      instead = "Set `username` and `password` in the `natsAuth` secret, or point `deps.natsAuth` at another secret.";
    }
    {
      keys = [ "accounts" ];
      unsupported = "All clients share the single login from `deps.natsAuth`, without NATS accounts.";
    }
    {
      keys = [
        "system_account"
        "system"
      ];
      unsupported = "All clients share the single login from `deps.natsAuth`, without NATS accounts.";
    }
    {
      keys = [
        "operator"
        "operators"
        "roots"
        "root"
        "root_operators"
        "root_operator"
      ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [
        "resolver"
        "account_resolver"
        "accounts_resolver"
      ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [ "resolver_tls" ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [ "resolver_preload" ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [ "resolver_pinned_accounts" ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [ "default_sentinel" ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [
        "trusted"
        "trusted_keys"
      ];
      unsupported = "Decentralized JWT authentication is unavailable; clients log in with the `username` and `password` in `deps.natsAuth`.";
    }
    {
      keys = [
        "leafnodes"
        "leaf"
      ];
      unsupported = "No Service or network policy exposes a leaf node port.";
    }
    {
      keys = [ "gateway" ];
      unsupported = "No Service or network policy exposes a gateway port.";
    }
    {
      keys = [
        "websocket"
        "ws"
      ];
      unsupported = "No Service or network policy exposes a WebSocket port.";
    }
    {
      keys = [ "mqtt" ];
      unsupported = "No Service or network policy exposes an MQTT port.";
    }
    {
      keys = [
        "mappings"
        "maps"
      ];
    }
    {
      keys = [
        "disable_sublist_cache"
        "no_sublist_cache"
      ];
    }
    {
      keys = [
        "max_connections"
        "max_conn"
      ];
    }
    {
      keys = [
        "max_subscriptions"
        "max_subs"
      ];
    }
    {
      keys = [
        "max_sub_tokens"
        "max_subscription_tokens"
      ];
    }
    {
      keys = [
        "no_system_account"
        "no_system"
        "no_sys_acc"
      ];
    }
  ];

  clusterEntries = ports: [
    {
      keys = [ "name" ];
      set = "The NATS cluster is named after the instance.";
    }
    {
      keys = [ "port" ];
      set = "Cluster routes between pods use port ${toString ports.cluster}.";
    }
    {
      keys = [ "listen" ];
      set = "Cluster routes between pods use port ${toString ports.cluster}.";
    }
    {
      keys = [
        "host"
        "net"
      ];
      set = "`nats-server` must listen on all network interfaces so peer pods can connect on port ${toString ports.cluster}.";
    }
    {
      keys = [ "routes" ];
      set = "This package builds the route list from `replicas` and the headless Service.";
    }
    {
      keys = [ "authorization" ];
      unsupported = "Cluster routes on port ${toString ports.cluster} connect without credentials; set `networkPolicy.enable = true` to restrict port ${toString ports.cluster} to the instance's own pods.";
    }
    {
      keys = [ "tls" ];
      unsupported = "Cluster routes between pods connect over plain TCP on port ${toString ports.cluster}.";
    }
    {
      keys = [
        "cluster_advertise"
        "advertise"
      ];
    }
  ];

  jetstreamEntries = [
    {
      keys = [
        "store_dir"
        "store"
        "storedir"
      ];
      set = "JetStream stores its files on the volume mounted at `/data`.";
      instead = "Set `storage.size` or `storage.storageClassName` on the instance to configure that volume.";
    }
    {
      keys = [
        "enabled"
        "enable"
      ];
      set = "The `jetstream.enabled` option controls whether JetStream runs.";
      instead = "Set `jetstream.enabled` on the instance.";
    }
    {
      keys = [
        "key"
        "ek"
        "encryption_key"
      ];
      unsupported = "Values in `settings` are stored in plain text in a ConfigMap, so JetStream encryption keys cannot be placed here.";
    }
    {
      keys = [
        "prev_key"
        "prev_ek"
        "prev_encryption_key"
      ];
      unsupported = "Values in `settings` are stored in plain text in a ConfigMap, so JetStream encryption keys cannot be placed here.";
    }
    {
      keys = [ "cipher" ];
      unsupported = "JetStream encryption at rest is unavailable because `settings` is stored in plain text in a ConfigMap.";
    }
    {
      keys = [ "tpm" ];
      unsupported = "JetStream encryption at rest is unavailable because `settings` is stored in plain text in a ConfigMap.";
    }
    {
      keys = [
        "max_file_store"
        "max_file"
      ];
    }
    {
      keys = [
        "max_memory_store"
        "max_mem_store"
        "max_mem"
      ];
    }
    {
      keys = [
        "sync_interval"
        "sync"
      ];
    }
  ];

  # Map every spelling to its entry.
  bySpelling =
    entries: lib.listToAttrs (lib.concatMap (e: map (k: lib.nameValuePair k e) e.keys) entries);

  # One problem per refused key of `block`, a value of `settings` at
  # `path`, against `entries`.
  blockProblems =
    path: entries: block:
    let
      table = bySpelling entries;
      shown = k: lib.concatStringsSep "." (path ++ [ k ]);
      one =
        k:
        let
          e = table.${k};
          canonical = builtins.head e.keys;
        in
        if lib.toLower k != k then
          {
            option = shown k;
            message = "`${shown k}` must be lowercase, so Kix did not build `nats.conf`. NATS ignores case in config keys, so mixed case can duplicate a key.";
            fix = "Rename `${shown k}` to `${shown (lib.toLower k)}`.";
          }
        else if !(table ? ${k}) then
          null
        else if e ? set then
          {
            option = shown k;
            message = "`${shown k}` cannot be set in `settings`, so Kix did not build `nats.conf`. ${e.set}";
            fix = "Remove `${shown k}`." + lib.optionalString (e ? instead) " ${e.instead}";
          }
        else if e ? unsupported then
          {
            option = shown k;
            message = "This package does not support `${shown k}`, so Kix did not build `nats.conf`. ${e.unsupported}";
            fix = "Remove `${shown k}`." + lib.optionalString (e ? instead) " ${e.instead}";
          }
        else if k != canonical then
          {
            option = shown k;
            message = "`${shown k}` is an alias for `${shown canonical}`, so Kix did not build `nats.conf`. Allowing both names in `settings` can make `nats-server` pick a different value on each restart.";
            fix = "Rename `${shown k}` to `${shown canonical}`.";
          }
        else
          null;
    in
    builtins.filter (p: p != null) (map one (builtins.attrNames block));
in
{
  # Return the problems of `settings` for an instance with `clustered` and
  # `jetstream` as given. A block the package does not write is refused as
  # a whole when its mode is off, and checked key by key when it is on.
  problems =
    {
      ports,
      clustered,
      jetstream,
    }:
    settings:
    let
      sub =
        key: on: what: entries:
        if !(settings ? ${key}) then
          [ ]
        else if !on then
          [
            {
              option = "settings.${key}";
              message = "`settings.${key}` is set while ${what}, so Kix did not build `nats.conf`.";
              fix =
                if key == "cluster" then
                  "Remove `settings.cluster`, or set `clustered = true` (with availability `pod`, `node`, or `zone`) to run a NATS cluster."
                else
                  "Remove `settings.jetstream`, or set `jetstream.enabled = true`.";
            }
          ]
        else if !builtins.isAttrs settings.${key} then
          [
            {
              option = "settings.${key}";
              message = "`settings.${key}` must be a `{ ... }` block of settings, so Kix did not build `nats.conf`.";
              fix =
                if key == "jetstream" then
                  "Put JetStream settings inside `settings.jetstream = { ... };`, or set `jetstream.enabled` on the instance to turn JetStream on or off."
                else
                  "Put cluster settings inside `settings.cluster = { ... };`, or set `clustered` on the instance to turn clustering on or off.";
            }
          ]
        else
          blockProblems [ "settings" key ] entries settings.${key};
    in
    blockProblems [ "settings" ] (topEntries ports) settings
    ++ sub "cluster" clustered "`clustered` is `false` (one standalone server)" (clusterEntries ports)
    ++ sub "jetstream" jetstream "`jetstream.enabled` is `false`" jetstreamEntries;
}
