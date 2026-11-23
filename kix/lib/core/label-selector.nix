# Kubernetes label selectors (`metav1.LabelSelector`), read the way the API
# server reads them. Every check that asks which objects a selector picks uses
# `matches`, so `matchLabels` and `matchExpressions` mean the same thing
# everywhere. A selector given as a plain label map, such as a Service's
# `spec.selector`, is wrapped as `{ matchLabels = map; }` by the caller.
{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
  inherit (import ./util.nix { inherit lib; }) attrsOr listOr;

  # Helm charts can render either field as an explicit null.
  matchLabelsOf = selector: attrsOr (selector.matchLabels or null);
  expressionsOf = selector: listOr (selector.matchExpressions or null);

  holds =
    labels: e:
    let
      has = labels ? ${e.key};
      values = e.values or [ ];
    in
    if e.operator == "In" then
      has && builtins.elem labels.${e.key} values
    else if e.operator == "NotIn" then
      !has || !(builtins.elem labels.${e.key} values)
    else if e.operator == "Exists" then
      has
    else if e.operator == "DoesNotExist" then
      !has
    else
      fail "label selector operator '${toString e.operator}' is not one of In, NotIn, Exists, DoesNotExist";
in
{
  # Return true when `labels` satisfies `selector`. An empty selector matches
  # every label set, as in Kubernetes. Callers that treat an empty selector as
  # selecting nothing check `isEmpty` first.
  matches =
    selector: labels:
    let
      matchLabels = matchLabelsOf selector;
    in
    builtins.all (k: labels ? ${k} && labels.${k} == matchLabels.${k}) (builtins.attrNames matchLabels)
    && builtins.all (holds labels) (expressionsOf selector);

  # Return `selector` as text in the form kubectl prints, such as
  # `team=apps, tier in (web, api), !legacy`.
  describe =
    selector:
    let
      expression =
        e:
        if e.operator == "In" then
          "${e.key} in (${lib.concatStringsSep ", " (map toString (e.values or [ ]))})"
        else if e.operator == "NotIn" then
          "${e.key} notin (${lib.concatStringsSep ", " (map toString (e.values or [ ]))})"
        else if e.operator == "Exists" then
          e.key
        else
          "!${e.key}";
    in
    lib.concatStringsSep ", " (
      lib.mapAttrsToList (k: v: "${k}=${toString v}") (matchLabelsOf selector)
      ++ map expression (expressionsOf selector)
    );

  # Return true when `selector` has no `matchLabels` and no `matchExpressions`.
  isEmpty = selector: matchLabelsOf selector == { } && expressionsOf selector == [ ];
}
