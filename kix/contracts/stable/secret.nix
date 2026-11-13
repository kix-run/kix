# Define the secret contract: what a package reads from a secret
# dependency (`kix.contracts.secret`).
#
# A package takes every secret value through a dependency that honours this
# contract, never through an option. The site picks the instance that fills
# it: `packages.secret` (plain text or a SOPS file), `packages.secret-ref`
# (a Secret something else writes), or any other source package. A source
# package built on `scope.mkSecret` or `scope.mkSecretRef` honours the
# contract by construction.
#
# A secret dependency has no fixed name: Grafana's is `grafanaAdmin`, caddy's
# is `caddyfile`. `alias` is `secret`, the default alias of the source
# packages, and `helpers.use` names the consumer's own argument in its
# messages.
{
  lib,
  compose,
  mkContract,
  ...
}:
let
  isFunction = builtins.isFunction;

  fields = {
    name = {
      required = true;
      shape = "the Secret's name";
      test = builtins.isString;
    };
    keys = {
      required = false;
      shape = "the list of keys the Secret holds";
      test = v: v == null || builtins.isList v;
    };
    keyRef = {
      required = true;
      shape = "a function from a key to an env var's valueFrom";
      test = isFunction;
    };
    mkEnv = {
      required = true;
      shape = "a function from { ENV_NAME = key; } to env entries";
      test = isFunction;
    };
    envFrom = {
      required = true;
      shape = "an envFrom entry for the whole Secret";
      test = builtins.isAttrs;
    };
    volume = {
      required = true;
      shape = "a function from a volume name to a volume";
      test = isFunction;
    };
    sops = {
      required = false;
      shape = "{ source; hash; }, the SOPS file Kix fills the Secret from, when it does";
      test = v: builtins.isAttrs v && v ? source && v ? hash;
    };
  };

  contract = mkContract {
    name = "secret";
    alias = "secret";
    remedyNoun = "secret";
    inherit fields;
    helpers = {
      # Validate the secret dependency `dep`, taken as the build argument
      # `arg`, against the contract and the keys the package reads, and
      # return it. A null `dep` (an optional dependency left unset) passes.
      # Read the Secret through the returned value so the checks run first.
      use =
        {
          who,
          arg,
          dep,
          keys ? [ ],
          anyOf ? null,
        }:
        let
          found = contract.problems (dep.out or { });
          name = dep.name or (dep.out.name or null);
          kind = dep.root.kind or (dep.raw.kind or (dep.kind or null));
          what =
            if kind == "PackageInstance" && builtins.isString name then
              "the instance ${name}"
            else if builtins.isString kind then
              "the ${kind}${lib.optionalString (builtins.isString name) " ${name}"}"
            else
              "something else";
        in
        if dep == null then
          null
        else if found != [ ] then
          throw "${who}: deps.${arg} must be a secret, but it is ${what}. Wire a secret instance, such as packages.secret (plain text or a SOPS file) or packages.secret-ref (a Secret something else writes), with deps.${arg} = ref.<ns>.<instance>."
        else
          compose.checkSecretKeys {
            inherit
              who
              arg
              dep
              keys
              anyOf
              ;
          };
    };
  };
in
contract
