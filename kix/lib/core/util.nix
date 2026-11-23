# Small value helpers shared across the library.
{ lib }:

{
  # Return `v` as a string without its string context, for use in attribute
  # names, messages, and comparisons.
  plain = v: builtins.unsafeDiscardStringContext (toString v);

  # Return `v` when it is a list, and `[ ]` otherwise. Helm charts can render
  # an explicit null, which `or` does not replace.
  listOr = v: if builtins.isList v then v else [ ];

  # Return `v` when it is an attribute set, and `{ }` otherwise, for the same
  # reason as `listOr`.
  attrsOr = v: if builtins.isAttrs v then v else { };

  # Return the API group of an `apiVersion`, or "" for the core group (`v1`).
  groupOf =
    apiVersion:
    let
      parts = lib.splitString "/" apiVersion;
    in
    if builtins.length parts > 1 then builtins.head parts else "";

  # Return the entries of a comma-separated annotation value, trimmed, without
  # empty entries.
  splitList = s: builtins.filter (x: x != "") (map lib.trim (lib.splitString "," (toString s)));

  # Return the namespace of a rendered manifest, or "cluster-scoped" for a
  # manifest without one.
  namespaceOf = m: m.metadata.namespace or "cluster-scoped";

  # Return a package's `reason` for a limit as the sentence messages add,
  # "Reason: <reason>.", or "" when `reason` is null. The full stop is added
  # when the reason has none.
  reasonSentence =
    reason:
    lib.optionalString (reason != null)
      "Reason: ${reason}${lib.optionalString (!(lib.hasSuffix "." (lib.trim reason))) "."}";

  # Return `instance` (`<namespace>/<name>`) as messages show it. `addedFor`
  # is null or the `_autoInstantiatedFor` list of an instance that
  # auto-instantiation added, and the label then names those instances.
  instanceLabel =
    instance: addedFor:
    if addedFor == null || addedFor == [ ] then
      instance
    else
      "${instance} (auto-instantiated for ${builtins.concatStringsSep ", " addedFor})";
}
