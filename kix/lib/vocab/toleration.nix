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
        description = "Taint key. Null with operator `Exists` tolerates every taint.";
      };
      operator = lib.mkOption {
        type = lib.types.enum [
          "Exists"
          "Equal"
        ];
        default = "Equal";
        description = "`Exists` matches any value of the key. `Equal` matches `value`.";
      };
      value = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint value for operator `Equal`.";
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
        description = "Taint effect to tolerate. Null tolerates every effect.";
      };
      tolerationSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "For effect `NoExecute`, how long the pod stays bound after the taint appears. Null keeps it bound.";
      };
    };
  };

  # Return the messages for each toleration in `tolerations` that the
  # apiserver would refuse. `optionPath` names the option, such as
  # "config.node.tolerations".
  problems =
    optionPath: tolerations:
    lib.concatLists (
      lib.imap0 (
        i: t:
        let
          at = "${optionPath}[${toString i}]";
        in
        lib.optional ((t.key == null || t.key == "") && t.operator != "Exists")
          "${at} has no key, which the apiserver accepts only with operator Exists (tolerate every taint). Set key, or set operator = \"Exists\"."
        ++
          lib.optional (t.operator == "Exists" && t.value != null)
            "${at} sets value with operator Exists, which matches any value, so the apiserver refuses it. Remove value, or set operator = \"Equal\"."
        ++
          lib.optional (t.tolerationSeconds != null && t.effect != "NoExecute")
            "${at} sets tolerationSeconds with effect ${
              if t.effect == null then "unset" else t.effect
            }, and the apiserver accepts tolerationSeconds only with effect NoExecute. Set effect = \"NoExecute\", or remove tolerationSeconds."
      ) tolerations
    );

  # Return the tolerations as a pod spec lists them, without the unset fields.
  render = map (lib.filterAttrs (_: v: v != null));
in
{
  inherit type problems render;
}
