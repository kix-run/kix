# valkey.conf and sentinel.conf for the valkey package: the directives the
# package owns, the checks on an instance's `settings` and
# `sentinel.primarySettings`, rendering, and the built-in maxmemory.
# kix/lib/tests/units/valkey.nix checks the messages.
{ lib, kix }:

let
  password = "the password comes from the valkeyPassword dependency";
  replication = "the start script points replicas at the primary Sentinel reports";
  announce = "the start script announces the pod's stable DNS name and port";
in
{
  # Directives the package writes or depends on, with the reason shown when
  # `settings` sets one. `port` is the valkey port the Services use.
  reservedSettings = port: {
    port = "the Services and probes use port ${toString port}";
    bind = "the Services, replication, and Sentinel reach valkey-server on the pod's address";
    requirepass = password;
    primaryauth = password;
    masterauth = password;
    primaryuser = "replicas authenticate to the primary as the default user with the valkeyPassword password";
    masteruser = "replicas authenticate to the primary as the default user with the valkeyPassword password";
    replicaof = replication;
    slaveof = replication;
    replica-announce-ip = announce;
    replica-announce-port = announce;
    dir = "the data volume is mounted at /data";
    include = "it would read a file outside the configuration the package renders";
    daemonize = "the container's process must stay in the foreground";
    user = "it bypasses the password from the valkeyPassword dependency";
    aclfile = "it bypasses the password from the valkeyPassword dependency";
    rename-command = "the probes, the preStop hook, and Sentinel call commands such as PING, ROLE, CLIENT, and REPLICAOF by name";
  };

  reservedPrimarySettings = {
    monitor = "the start script monitors the primary it finds";
    auth-pass = password;
    auth-user = "Sentinel authenticates as the default user with the valkeyPassword password";
    known-replica = "Sentinel discovers replicas itself";
    known-sentinel = "Sentinel discovers its peers itself";
    config-epoch = "Sentinel keeps it in its own state";
    leader-epoch = "Sentinel keeps it in its own state";
    rename-command = "valkey-server keeps every command under its own name";
  };

  # A value written on one config line. A line break would start another
  # directive that the reserved-key check never sees.
  lineStr = lib.types.addCheck lib.types.str (s: builtins.match "[^\n\r]*" s != null) // {
    description = "string without line breaks";
  };

  # Return the errors, as `scope.fail` takes them, for one map of
  # directives at `option`, one per offending key. A key is a directive
  # name: lower case letters, digits, and hyphens.
  refusals =
    option: reserved: settings:
    builtins.concatMap (
      key:
      let
        lower = lib.toLower key;
      in
      if reserved ? ${lower} then
        [
          {
            inherit option;
            message = "${option}.${key} is set by the package: ${reserved.${lower}}. Remove it.";
          }
        ]
      else if builtins.match "[a-z0-9-]+" lower == null then
        [
          {
            inherit option;
            message = "${option}.${builtins.toJSON key} is not a directive name. Use the name alone, in lower case letters, digits, and hyphens, and put the arguments in the value.";
          }
        ]
      else if lower != key then
        [
          {
            inherit option;
            message = "${option}.${key} is not lower case. Valkey matches directive names case-insensitively, so write it as ${option}.${lower}.";
          }
        ]
      else
        [ ]
    ) (builtins.attrNames settings);

  # The built-ins with the instance's map over them; null drops a key.
  overlay = builtIns: settings: lib.filterAttrs (_: v: v != null) (builtIns // settings);

  # Config text for a map of directives. `prefixOf key` is the start of
  # each line; a bool renders yes or no, a list one line per element.
  render =
    prefixOf: directives:
    let
      linesOf =
        key: value:
        let
          prefix = prefixOf key;
        in
        if builtins.isBool value then
          [ "${prefix} ${if value then "yes" else "no"}" ]
        else if builtins.isList value then
          map (v: "${prefix} ${v}") value
        else
          [ "${prefix} ${toString value}" ];
    in
    lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList linesOf directives)) + "\n";

  # The built-in maxmemory in bytes, as a string, for a container memory
  # limit; null without one. maxmemory counts the dataset only.
  # Replication and client buffers, and the pages the AOF rewrite fork
  # copies on write, share the container's limit, so the dataset gets 70%
  # of it. Valkey's default maxmemory-policy, noeviction, then fails writes
  # when the dataset is full instead of the kernel killing the pod.
  maxmemoryFor =
    limit:
    if limit == null then
      null
    else
      toString (builtins.floor (kix.parseQuantity "memory" limit * 7 / 10));
}
