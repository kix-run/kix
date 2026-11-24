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
      set = "this package listens for clients on port ${toString ports.client} so the client Service, health check, and `out.port` match.";
    }
    {
      keys = [ "listen" ];
      set = "this package listens for clients on port ${toString ports.client} so the client Service, health check, and `out.port` match.";
    }
    {
      keys = [
        "host"
        "net"
      ];
      set = "the server must listen on all network interfaces so Kubernetes Services and probes can reach it.";
    }
    {
      keys = [ "client_advertise" ];
      set = "clients connect through the client Service, so pods do not advertise individual pod addresses.";
    }
    {
      keys = [
        "http_port"
        "monitor_port"
      ];
      set = "the pod probes, monitoring Service, and metrics exporter all use port ${toString ports.monitor}.";
    }
    {
      keys = [ "http" ];
      set = "the pod probes, monitoring Service, and metrics exporter all use port ${toString ports.monitor}.";
    }
    {
      keys = [
        "https"
        "https_port"
      ];
      set = "the pod probes and metrics exporter read the monitoring endpoint over plain HTTP.";
    }
    {
      keys = [ "http_base_path" ];
      set = "the pod probes check `/healthz` at the root path `/`.";
    }
    {
      keys = [ "server_name" ];
      set = "this package names each server after its pod so JetStream keeps its peer identity across restarts.";
    }
    {
      keys = [
        "pid_file"
        "pidfile"
      ];
      set = "the `preStop` hook reads `/var/run/nats/nats.pid` to drain connections before shutdown.";
    }
    {
      keys = [ "lame_duck_duration" ];
      set = "lame duck mode lasts at most 30 seconds, of which the first 10 seconds are the grace period before clients are closed, and `terminationGracePeriodSeconds` is set to 60 to leave room for it.";
    }
    {
      keys = [ "lame_duck_grace_period" ];
      set = "lame duck mode lasts at most 30 seconds, of which the first 10 seconds are the grace period before clients are closed, and `terminationGracePeriodSeconds` is set to 60 to leave room for it.";
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
      set = "the container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [
        "logfile_size_limit"
        "log_size_limit"
      ];
      set = "the container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [
        "logfile_max_num"
        "log_max_num"
      ];
      set = "the container's root filesystem is read-only, and `nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [ "syslog" ];
      set = "`nats-server` logs to standard output for `kubectl logs`.";
    }
    {
      keys = [ "remote_syslog" ];
      unsupported = "remote syslog is not supported because generated network policies do not open egress to a syslog server.";
    }
    {
      keys = [ "ports_file_dir" ];
      set = "the container's root filesystem is read-only, and Kubernetes Services already expose the server's fixed ports.";
    }
    {
      keys = [ "prof_port" ];
      unsupported = "the Go profiling port is not supported because no Service or network policy exposes it.";
    }
    {
      keys = [ "tls" ];
      unsupported = "client TLS is not supported; `out.url` and the post-deploy health check connect over plain `nats://`.";
    }
    {
      keys = [ "allow_non_tls" ];
      unsupported = "client TLS is not supported; `out.url` and the post-deploy health check connect over plain `nats://`.";
    }
    {
      keys = [ "authorization" ];
      set = "client authentication is configured from the `natsAuth` secret dependency.";
      instead = "Change client credentials in the `natsAuth` secret or via `deps.natsAuth`.";
    }
    {
      keys = [ "no_auth_user" ];
      set = "client authentication is configured from the `natsAuth` secret dependency.";
      instead = "Change client credentials in the `natsAuth` secret or via `deps.natsAuth`.";
    }
    {
      keys = [ "accounts" ];
      unsupported = "NATS accounts are not supported; all clients authenticate with the login in `deps.natsAuth`.";
    }
    {
      keys = [
        "system_account"
        "system"
      ];
      unsupported = "NATS accounts are not supported; all clients authenticate with the login in `deps.natsAuth`.";
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
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [
        "resolver"
        "account_resolver"
        "accounts_resolver"
      ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [ "resolver_tls" ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [ "resolver_preload" ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [ "resolver_pinned_accounts" ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [ "default_sentinel" ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [
        "trusted"
        "trusted_keys"
      ];
      unsupported = "decentralized JWT authentication is not supported; clients authenticate with the `natsAuth` secret dependency.";
    }
    {
      keys = [
        "leafnodes"
        "leaf"
      ];
      unsupported = "leaf nodes are not supported because no Service or network policy exposes a leaf node port.";
    }
    {
      keys = [ "gateway" ];
      unsupported = "gateways are not supported because no Service or network policy exposes a gateway port.";
    }
    {
      keys = [
        "websocket"
        "ws"
      ];
      unsupported = "WebSocket connections are not supported because no Service or network policy exposes a WebSocket port.";
    }
    {
      keys = [ "mqtt" ];
      unsupported = "MQTT is not supported because no Service or network policy exposes an MQTT port.";
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
      set = "this package names the NATS cluster after the instance.";
    }
    {
      keys = [ "port" ];
      set = "the headless Service and cluster routes use port ${toString ports.cluster}.";
    }
    {
      keys = [ "listen" ];
      set = "the headless Service and cluster routes use port ${toString ports.cluster}.";
    }
    {
      keys = [
        "host"
        "net"
      ];
      set = "the server must listen on all network interfaces so peer pods can connect over cluster routes.";
    }
    {
      keys = [ "routes" ];
      set = "this package generates the route list automatically from the StatefulSet replicas and headless Service.";
    }
    {
      keys = [ "authorization" ];
      unsupported = "cluster route authentication is not supported.";
    }
    {
      keys = [ "tls" ];
      unsupported = "cluster route TLS is not supported.";
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
      set = "JetStream is turned on or off with the `jetstream.enabled` option.";
      instead = "Set `jetstream.enabled` on the instance instead.";
    }
    {
      keys = [
        "key"
        "ek"
        "encryption_key"
      ];
      unsupported = "JetStream encryption at rest is not supported because values in `settings` are stored in plain text in a ConfigMap.";
    }
    {
      keys = [
        "prev_key"
        "prev_ek"
        "prev_encryption_key"
      ];
      unsupported = "JetStream encryption at rest is not supported because values in `settings` are stored in plain text in a ConfigMap.";
    }
    {
      keys = [ "cipher" ];
      unsupported = "JetStream encryption at rest is not supported.";
    }
    {
      keys = [ "tpm" ];
      unsupported = "TPM-sealed JetStream encryption keys are not supported because values in `settings` are stored in plain text in a ConfigMap.";
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
            message = "`${shown k}` uses uppercase letters, so Kix cannot build `nats.conf`. NATS ignores letter case in config keys, so `settings`, `settings.cluster`, and `settings.jetstream` accept lowercase keys only.";
            fix = "Rename the key to `${lib.toLower k}`.";
          }
        else if !(table ? ${k}) then
          null
        else if e ? set then
          {
            option = shown k;
            message = "`${shown k}` conflicts with a setting managed by this package, so Kix cannot build `nats.conf`: ${e.set}";
            fix = "Remove `${shown k}` from `settings`." + lib.optionalString (e ? instead) " ${e.instead}";
          }
        else if e ? unsupported then
          {
            option = shown k;
            message = "`${shown k}` is not supported by this package, so Kix cannot build `nats.conf`: ${e.unsupported}";
            fix = "Remove `${shown k}` from `settings`." + lib.optionalString (e ? instead) " ${e.instead}";
          }
        else if k != canonical then
          {
            option = shown k;
            message = "`${shown k}` is an alias for `${canonical}`, so Kix cannot build `nats.conf`. If both names appear in one file, `nats-server` can pick a different value on each restart.";
            fix = "Rename the key to `${canonical}`.";
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
              message = "`settings.${key}` cannot be set while ${what}, so Kix cannot build `nats.conf`.";
              fix =
                if key == "cluster" then
                  "Remove `settings.cluster`, or set `replicas = 3` to run a NATS cluster."
                else
                  "Remove `settings.jetstream`, or set `jetstream.enabled = true`.";
            }
          ]
        else if !builtins.isAttrs settings.${key} then
          [
            {
              option = "settings.${key}";
              message = "`settings.${key}` must be a `{ ... }` block of settings so Kix can merge it into `nats.conf`; Kix rejected the non-block value.";
              fix =
                if key == "jetstream" then
                  "Set individual keys inside `settings.${key} = { ... };`, or set `jetstream.enabled` on the instance to turn JetStream on or off."
                else
                  "Set individual keys inside `settings.${key} = { ... };`.";
            }
          ]
        else
          blockProblems [ "settings" key ] entries settings.${key};
    in
    blockProblems [ "settings" ] (topEntries ports) settings
    ++ sub "cluster" clustered "`replicas` is 1 (single-server mode)" (clusterEntries ports)
    ++ sub "jetstream" jetstream "`jetstream.enabled` is `false`" jetstreamEntries;
}
