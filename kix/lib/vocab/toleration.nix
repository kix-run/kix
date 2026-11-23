# Define the pod toleration option type (`kix.types.toleration`) and the
# helpers that check and render a list of them (`kix.tolerations`).
#
# The type mirrors the fields of a Kubernetes toleration. The apiserver
# refuses some combinations of them, and a submodule cannot check one field
# against another, so a package passes each list to `problems` in its
# assertions.
{ lib }:

let
  type = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint key to match. Leave unset with `operator = \"Exists\"` to match all taint keys.";
      };
      operator = lib.mkOption {
        type = lib.types.enum [
          "Exists"
          "Equal"
        ];
        default = "Equal";
        description = "How to match the taint: `\"Equal\"` matches `key` and `value`, and `\"Exists\"` matches any value for `key` (or all taints when `key` is unset).";
      };
      value = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint value to match when `operator` is `\"Equal\"`. Leave unset when `operator` is `\"Exists\"`.";
      };
      effect = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "NoSchedule"
            "PreferNoSchedule"
            "NoExecute"
          ]
        );
        default = null;
        description = "Taint effect to tolerate. Leave unset to tolerate all effects.";
      };
      tolerationSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Seconds a pod stays on a node after a matching `NoExecute` taint is added before Kubernetes evicts it. Leave unset to keep the pod on the node indefinitely. Requires `effect = \"NoExecute\"`.";
      };
    };
  };

  # Return the messages for each toleration in `tolerations` that the
  # apiserver would refuse. `optionPath` names the option, such as
  # "config.node.tolerations".
  problems =
    { optionPath, tolerations }:
    lib.concatLists (
      lib.imap0 (
        i: t:
        let
          at = "${optionPath}[${toString i}]";
        in
        lib.optional ((t.key == null || t.key == "") && t.operator != "Exists")
          "${at} has a missing or empty key. Kubernetes rejects a toleration without a key unless operator is \"Exists\" (which matches all taints). Set a non-empty key, or set operator = \"Exists\"."
        ++
          lib.optional (t.operator == "Exists" && t.value != null)
            "${at} sets value with operator \"Exists\". Because \"Exists\" matches any taint value, Kubernetes rejects a value field here. Remove value, or set operator = \"Equal\"."
        ++
          lib.optional (t.tolerationSeconds != null && t.effect != "NoExecute")
            "${at} sets tolerationSeconds while effect is ${
              if t.effect == null then "unset" else t.effect
            }. Kubernetes allows tolerationSeconds only when effect is \"NoExecute\". Set effect = \"NoExecute\", or remove tolerationSeconds."
      ) tolerations
    );

  # Return the tolerations as a pod spec lists them, without the unset fields.
  render = map (lib.filterAttrs (_: v: v != null));
in
{
  inherit type problems render;
}
