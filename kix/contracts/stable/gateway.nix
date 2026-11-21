# Define the `gateway` contract for packages that answer the `gateway` alias
# and expose a Gateway API Gateway on `root.out` (`kix.contracts.gateway`).
#
# Provider packages call `check`, which requires every field. `kix.expose`
# validates its `gateway` dependency with `require`, which requires only the
# `required` fields so a `kix.mkImport` stand-in only needs to publish
# `gatewayRef`.
{
  lib,
  mkContract,
  ...
}:
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
    # Lets a package refuse to expose something that must not face the
    # internet, such as an administration page with no login. A provider
    # says false only when it knows the Gateway cannot be reached from
    # outside the cluster, so a reader treats null as true.
    public = {
      required = false;
      shape = "a boolean indicating whether the Gateway may be reachable from outside the cluster, or null when unknown";
      test = v: v == null || builtins.isBool v;
    };
  };
in
mkContract {
  name = "gateway";
  alias = "gateway";
  inherit fields;
  # A network policy requires both selector and namespace.
  extraProblems =
    out:
    lib.optional (
      (out.podSelector or null == null) != (out.podNamespace or null == null)
    ) "podSelector and podNamespace must both be set or both be null";

  helpers = {
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
  };
}
