# The `clickhouse` contract: what every package answering the alias
# promises on root.out.
#
# Two implementations honour it today, `clickhouse` (one node) and
# `clickhouse-cluster` (the Altinity operator). Each passes its out through
# `check`, and `clickhouse-database` holds its dep to the same table through
# `assertions`, so a third implementation is checked at eval on both sides
# and the error names the field and the package.
#
# `checks.clickhouse-swap` in flake.nix proves something different: that a
# consumer renders the same on both. This file is the definition.
{ lib }:
let
  inherit (import ../../../lib/vocab/contract.nix { inherit lib; }) credentialsField;
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

  problems =
    out:
    builtins.concatMap (
      field:
      if !(out ? ${field}) then
        [ "${field} is missing (${fields.${field}.shape})" ]
      else if !(fields.${field}.test out.${field}) then
        [ "${field} is not ${fields.${field}.shape}" ]
      else
        [ ]
    ) (builtins.attrNames fields);

  here = "kix/packages/stable/clickhouse/contract.nix";
in
{
  alias = "clickhouse";
  inherit fields problems;

  # Verify that an implementation's `root.out` satisfies the contract:
  # `root.out = contract.check "clickhouse (x)" { ... }`.
  check =
    who: out:
    let
      found = problems out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the clickhouse contract: ${lib.concatStringsSep "; " found} (${here})";

  # Build `deps.clickhouse.assertions` for a consumer:
  # `deps.clickhouse.assertions = dep: contract.assertions "x" dep.out;`.
  assertions =
    who: out:
    lib.optional (problems out != [ ]) {
      assertion = false;
      message = "${who}: the clickhouse instance it resolved to does not honour the clickhouse contract: ${lib.concatStringsSep "; " (problems out)} (${here})";
    };
}
