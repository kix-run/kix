# Define the `gateway` contract for packages that answer the `gateway` alias
# and expose a Gateway API Gateway on `root.out` (`kix.contracts.gateway`).
#
# Provider packages call `check`, which requires every field. `kix.expose`
# validates its `gateway` dependency with `require`, which requires only the
# `required` fields so a `kix.mkImport` stand-in only needs to publish
# `gatewayRef`.
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
    # Used by `kix.expose` to select the target listener and derive the route's
    # scheme and port. Without `listeners`, reading `exposure.url` throws.
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
    # Identifies the data-plane pods so `kix.expose` can generate an ingress
    # network policy on each exposed backend. Set to null when the provider
    # cannot determine where the data plane runs.
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

  # Return a list of validation errors for `out`. When `all` is true, require
  # optional fields as well.
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
    # A network policy requires both selector and namespace.
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

  # Return the contract violations a consumer reports for `out`.
  problems = problemsWith false;

  # Validate a provider's `root.out` and return it, or throw if any field is
  # missing or malformed.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the gateway contract: ${lib.concatStringsSep "; " found} (${here})";

  # Return true when `dep` declares the `gateway` alias or publishes
  # `gatewayRef`. Because dependencies can also resolve by instance name,
  # `kix.expose` uses this check to ignore unrelated instances named `gateway`.
  claims =
    dep:
    let
      meta = dep._meta or { };
      aliases = (meta.aliases or [ ]) ++ ((meta.packageMeta or { }).defaultAliases or [ ]);
    in
    (dep.out or { }) ? gatewayRef || builtins.elem "gateway" aliases;

  # Validate a consumer's `gateway` dependency and return `dep`, or throw if
  # any required field is missing or any present field is malformed.
  require =
    who: dep:
    let
      found = problemsWith false (dep.out or { });
    in
    if found == [ ] then dep else throw (consumerMessage who dep found);
}
