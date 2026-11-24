# Kubernetes label selectors (`metav1.LabelSelector`), read the way the API
# server reads them. Every check that asks which objects a selector picks uses
# `matches`, so `matchLabels` and `matchExpressions` mean the same thing
# everywhere. A selector given as a plain label map, such as a Service's
# `spec.selector`, is wrapped as `{ matchLabels = map; }` by the caller.
{ lib }:

let
  inherit (import ./util.nix { inherit lib; }) attrsOr listOr;

  # Helm charts can render either field as an explicit null.
  matchLabelsOf = selector: attrsOr (selector.matchLabels or null);
  expressionsOf = selector: listOr (selector.matchExpressions or null);

  operators = [
    "In"
    "NotIn"
    "Exists"
    "DoesNotExist"
  ];

  # Return what is wrong with one expression, or null.
  expressionProblem =
    e:
    if !(builtins.isAttrs e) then
      "matchExpressions contains ${builtins.toJSON e}; each entry must be an object with 'key' and 'operator'. Replace it with an entry that sets 'key' to a label name and 'operator' to \"In\", \"NotIn\", \"Exists\", or \"DoesNotExist\"."
    else if (e.key or null) == null then
      "matchExpressions entry ${builtins.toJSON e} is missing 'key'. Set 'key' on that entry to the label name to match."
    else if !(builtins.isString e.key) then
      "matchExpressions entry ${builtins.toJSON e} sets 'key' to ${builtins.toJSON e.key}; 'key' must be a string. Set 'key' to the label name."
    else if (e.operator or null) == null then
      "the matchExpressions entry for key '${e.key}' is missing 'operator'. Set 'operator' to \"In\", \"NotIn\", \"Exists\", or \"DoesNotExist\"."
    else if !(builtins.elem e.operator operators) then
      let
        shown = if builtins.isString e.operator then "'${e.operator}'" else builtins.toJSON e.operator;
      in
      "the matchExpressions entry for key '${e.key}' sets operator ${shown}, which Kubernetes rejects. Set 'operator' to \"In\", \"NotIn\", \"Exists\", or \"DoesNotExist\"."
    else
      null;

  # An expression with a problem never holds, so a malformed selector matches
  # nothing. `problems` reports why.
  holds =
    labels: e:
    let
      has = labels ? ${e.key};
      values = listOr (e.values or null);
    in
    if expressionProblem e != null then
      false
    else if e.operator == "In" then
      has && builtins.elem labels.${e.key} values
    else if e.operator == "NotIn" then
      !has || !(builtins.elem labels.${e.key} values)
    else if e.operator == "Exists" then
      has
    else
      !has;
in
{
  # The change record for the checks that started to read `matchExpressions`.
  # Their refusals print it.
  recordId = "K1895";

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
        let
          key = toString (e.key or "?");
          operator = e.operator or "?";
          values = "(${lib.concatStringsSep ", " (map toString (listOr (e.values or null)))})";
        in
        if !(builtins.isAttrs e) then
          builtins.toJSON e
        else if operator == "In" then
          "${key} in ${values}"
        else if operator == "NotIn" then
          "${key} notin ${values}"
        else if operator == "Exists" then
          key
        else if operator == "DoesNotExist" then
          "!${key}"
        else
          "${key} ${toString operator} ${values}";
    in
    lib.concatStringsSep ", " (
      lib.mapAttrsToList (k: v: "${k}=${toString v}") (matchLabelsOf selector)
      ++ map expression (expressionsOf selector)
    );

  # Return what is wrong with `selector`, as a list of sentences. Kubernetes
  # rejects an object whose selector has a problem.
  problems =
    selector: builtins.filter (p: p != null) (map expressionProblem (expressionsOf selector));

  # Return true when `selector` has no `matchLabels` and no `matchExpressions`.
  isEmpty = selector: matchLabelsOf selector == { } && expressionsOf selector == [ ];
}
