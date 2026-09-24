# The `clickhouse` contract: what every package answering the alias
# promises on root.out (v2_discussions/148 §1).
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
    authSecret = {
      shape = "a secret instance (out.keyRef)";
      test = v: builtins.isAttrs v && builtins.isFunction ((v.out or { }).keyRef or null);
    };
    authPasswordKey = {
      shape = "the key of authSecret holding the password";
      test = isString;
    };
    clusterName = {
      shape = "what the {cluster} macro expands to";
      test = isString;
    };
    version = {
      shape = "the server release as YY.M";
      test = isVersion;
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

  here = "kix/packages/clickhouse/contract.nix";
in
{
  alias = "clickhouse";
  inherit fields problems;

  # For an implementation: `root.out = contract.check "clickhouse (x)" { ... }`.
  check =
    who: out:
    let
      found = problems out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the clickhouse contract: ${lib.concatStringsSep "; " found} (${here})";

  # For a consumer: `deps.clickhouse.assertions = dep: contract.assertions "x" dep.out;`.
  assertions =
    who: out:
    lib.optional (problems out != [ ]) {
      assertion = false;
      message = "${who}: the clickhouse instance it resolved to does not honour the clickhouse contract: ${lib.concatStringsSep "; " (problems out)} (${here})";
    };
}
