# The `gateway` contract: what a package answering the `gateway` alias
# publishes on root.out, for one Gateway API Gateway that kix.expose attaches
# HTTPRoutes to. A consumer written against these fields runs on any
# implementation that honours them (envoy-gateway, traefik, a kix.mkImport).
#
# A provider package passes its out through `check`, which requires every
# field. kix.expose holds its `gateway` dependency to the contract through
# `require`, which requires the fields marked `required` and checks the
# shape of the others when they are present, so a kix.mkImport stand-in may
# publish only `gatewayRef`. Packages reach this file as
# `kix.contracts.gateway`.
{ lib }:
let
  isString = builtins.isString;
  isStringAttrs = v: builtins.isAttrs v && lib.all isString (builtins.attrValues v);

  fields = {
    gatewayRef = {
      required = true;
      shape = "{ name; namespace; } naming the Gateway, the parentRef of every HTTPRoute";
      test = v: builtins.isAttrs v && isString (v.name or null) && isString (v.namespace or null);
    };
    # kix.expose picks the listener a route attaches to, and from it the
    # URL's scheme and port. Without them `exposure.url` throws.
    listeners = {
      required = false;
      shape = "the Gateway's spec.listeners, each with name, port (an integer), and protocol";
      test =
        v:
        builtins.isList v
        && lib.all (
          l:
          builtins.isAttrs l
          && isString (l.name or null)
          && builtins.isInt (l.port or null)
          && isString (l.protocol or null)
        ) v;
    };
    # The data-plane pods, for the policy kix.expose writes so they can
    # reach each exposed backend. Null when the package cannot know where
    # the implementation runs them.
    podSelector = {
      required = false;
      shape = "the data-plane pods' labels as a non-empty attrset of strings, or null when the provider cannot tell";
      test = v: v == null || (isStringAttrs v && v != { });
    };
    podNamespace = {
      required = false;
      shape = "the data-plane pods' namespace, or null when the provider cannot tell";
      test = v: v == null || isString v;
    };
  };

  # Problems with `out`, one string per field. `all` requires every field;
  # otherwise only the required ones.
  problemsWith =
    all: out:
    builtins.concatMap (
      field:
      let
        f = fields.${field};
      in
      if !(out ? ${field}) then
        lib.optional (all || f.required) "${field} is missing (${f.shape})"
      else if !(f.test out.${field}) then
        [ "${field} is not ${f.shape}" ]
      else
        [ ]
    ) (builtins.attrNames fields)
    # A policy needs both, so one without the other is a mistake.
    ++ lib.optional (
      (out.podSelector or null == null) != (out.podNamespace or null == null)
    ) "podSelector and podNamespace must both be set or both be null";

  here = "kix/lib/vocab/gateway.nix";

  providerOf =
    dep:
    let
      meta = dep._meta or { };
    in
    if meta ? namespaceName && meta ? instanceName then
      "${meta.namespaceName}/${meta.instanceName}"
    else
      "the instance it resolved to";

  consumerMessage =
    who: dep: found:
    "${who}: deps.gateway resolved to ${providerOf dep}, whose out does not honour the gateway contract: ${lib.concatStringsSep "; " found}. Set them on that instance's out (a kix.mkImport sets them in `out`), or wire another gateway with deps.gateway = ref.<ns>.<instance> (${here}).";
in
{
  alias = "gateway";
  inherit fields;

  # The problems a consumer reports for `out`.
  problems = problemsWith false;

  # For a provider: `root.out = kix.contracts.gateway.check who { ... }`.
  # Returns `out`, or throws naming every missing or misshapen field.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the gateway contract: ${lib.concatStringsSep "; " found} (${here})";

  # Whether `dep` offers itself as a gateway: its out has `gatewayRef`, or
  # the instance or its package names the `gateway` alias. A dependency
  # argument also resolves by instance name, so an unrelated instance named
  # `gateway` claims nothing and kix.expose ignores it.
  claims =
    dep:
    let
      meta = dep._meta or { };
      aliases = (meta.aliases or [ ]) ++ ((meta.packageMeta or { }).defaultAliases or [ ]);
    in
    (dep.out or { }) ? gatewayRef || builtins.elem "gateway" aliases;

  # For kix.expose, which has no assertion hook: returns `dep`, or throws
  # naming the provider and every missing or misshapen field.
  require =
    who: dep:
    let
      found = problemsWith false (dep.out or { });
    in
    if found == [ ] then dep else throw (consumerMessage who dep found);
}
