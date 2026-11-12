# Define the ClickHouse contract for packages that answer the `clickhouse`
# alias and publish connection details on `root.out`
# (`kix.contracts.experimental.clickhouse`).
#
# Two packages provide it, `clickhouse` (one node) and `clickhouse-cluster`
# (the Altinity operator). Each passes its out through `check`, and
# `clickhouse-database` validates its dependency with `assertions`, so a
# third provider is checked on both sides and the error names the field
# and the package.
#
# `checks.clickhouse-swap` in flake.nix proves something different: that a
# consumer renders the same on both. This file is the definition.
{
  lib,
  mkContract,
  credentialsField,
  ...
}:
let
  isString = builtins.isString;
  # A ClickHouse release is YY.M.patch.build; the contract carries YY.M,
  # which is what a consumer's requirement compares against.
  isVersion = v: isString v && builtins.match "[0-9]+\\.[0-9]+" v != null;

  fields = {
    httpUrl = {
      shape = "an http:// URL to the HTTP interface";
      test = v: isString v && lib.hasPrefix "http://" v;
    };
    nativeEndpoint = {
      shape = "host:port of the native interface";
      test = v: isString v && lib.hasInfix ":" v;
    };
    host = {
      shape = "the Service FQDN";
      test = isString;
    };
    ports = {
      shape = "{ http; native; } as strings";
      test = v: builtins.isAttrs v && isString (v.http or null) && isString (v.native or null);
    };
    username = {
      shape = "the administrative user";
      test = isString;
    };
    # The administrator's password; `username` names the user.
    credentials = credentialsField { keys = [ "password" ]; };
    clusterName = {
      shape = "what the {cluster} macro expands to";
      test = isString;
    };
    version = {
      shape = "the server release as YY.M";
      test = isVersion;
    };
    # A consumer whose upstream creates plain MergeTree tables can run only
    # where the shard has one replica: on more, each connection may land on
    # a replica that lacks the table.
    replicas = {
      shape = "the shard's replica count as a string of digits";
      test = v: isString v && builtins.match "[1-9][0-9]*" v != null;
    };
    # One address per replica, in replica order, each serving the HTTP port
    # of `ports`. A consumer that must run statements on one particular
    # replica (migrations that create plain tables) connects to one of
    # these instead of the load-balanced `host`.
    replicaHosts = {
      shape = "a list of one FQDN per replica, as many as `replicas`";
      test = v: builtins.isList v && v != [ ] && builtins.all isString v;
    };
  };
in
mkContract {
  name = "ClickHouse";
  alias = "clickhouse";
  remedyNoun = "ClickHouse server";
  inherit fields;
}
