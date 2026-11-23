# Tests for `kix.types.toleration` with `kix.tolerations`, and
# `kix.types.volumeSnapshotClass` with `kix.storage.snapshotClassProblems`,
# as packages receive them.

{
  lib,
  kixlib,
  ...
}:

let
  kix = kixlib;

  # Merge `value` into a list option or an attrset option of `type`, as a
  # package's options would.
  evalList =
    type: value:
    (lib.evalModules {
      modules = [
        {
          options.v = lib.mkOption {
            type = lib.types.listOf type;
            default = [ ];
          };
          config.v = value;
        }
      ];
    }).config.v;

  evalAttrs =
    type: value:
    (lib.evalModules {
      modules = [
        {
          options.v = lib.mkOption {
            type = lib.types.attrsOf type;
            default = { };
          };
          config.v = value;
        }
      ];
    }).config.v;

  tolerations = evalList kix.types.toleration;
  problems =
    tolerations:
    kix.tolerations.problems {
      optionPath = "config.tolerations";
      inherit tolerations;
    };
  has = fragment: builtins.any (lib.hasInfix fragment);

  classes = evalAttrs kix.types.volumeSnapshotClass;
  classProblems =
    value: snapshotController:
    kix.storage.snapshotClassProblems {
      optionPath = "config.volumeSnapshotClasses";
      classes = classes value;
      inherit snapshotController;
    };
  isDefault.annotations."snapshot.storage.kubernetes.io/is-default-class" = "true";
in
{
  # A valid list renders without its unset fields, and each refused
  # combination names the entry.
  lib-csi-vocab-tolerations =
    let
      valid = tolerations [
        {
          key = "storage";
          operator = "Exists";
          effect = "NoExecute";
          tolerationSeconds = 30;
        }
        { operator = "Exists"; }
      ];
      cases = {
        valid = problems valid == [ ];
        rendered =
          kix.tolerations.render valid == [
            {
              key = "storage";
              operator = "Exists";
              effect = "NoExecute";
              tolerationSeconds = 30;
            }
            { operator = "Exists"; }
          ];
        noKey = has "config.tolerations[0] has no key" (
          problems (tolerations [ { effect = "NoSchedule"; } ])
        );
        # Kubernetes refuses an empty key with operator Equal as it refuses
        # a missing one.
        emptyKey = has "config.tolerations[0] has no key" (problems (tolerations [ { key = ""; } ]));
        existsWithValue = has "config.tolerations[0] sets value with operator \"Exists\"" (
          problems (tolerations [
            {
              key = "k";
              operator = "Exists";
              value = "v";
            }
          ])
        );
        secondsWithoutNoExecute = has "config.tolerations[1] sets tolerationSeconds while effect is unset" (
          problems (tolerations [
            { operator = "Exists"; }
            {
              key = "k";
              operator = "Exists";
              tolerationSeconds = 10;
            }
          ])
        );
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "tolerations (true is the expected result for each): ${builtins.toJSON cases}";

  lib-csi-vocab-snapshot-class-problems =
    let
      cases = {
        valid = classProblems { a = isDefault; } { } == [ ];
        noProvider =
          has "config.volumeSnapshotClasses defines a, but nothing provides the snapshotController role"
            (classProblems { a = { }; } null);
        threeDefaults =
          has
            "config.volumeSnapshotClasses.a, config.volumeSnapshotClasses.b, and config.volumeSnapshotClasses.c each set"
            (
              classProblems {
                a = isDefault;
                b = isDefault;
                c = isDefault;
              } { }
            );
        reserved = has "config.volumeSnapshotClasses.root: Kix reserves the names \"root\" and \"meta\"" (
          classProblems { root = { }; } { }
        );
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "snapshot class problems (true is the expected result for each): ${builtins.toJSON cases}";
}
