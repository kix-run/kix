# Tests for the one label selector matcher (core/label-selector.nix).

{ lib, ... }:

let
  inherit (import ../../core/label-selector.nix { inherit lib; }) matches isEmpty describe;

  labels = {
    team = "apps";
    tier = "web";
  };

  # The indexes of the cases that do not hold.
  failing =
    cases: builtins.filter (i: !(builtins.elemAt cases i)) (lib.range 0 (builtins.length cases - 1));
  check =
    what: cases: failing cases == [ ] || throw "${what}: cases ${builtins.toJSON (failing cases)} fail";
in
{
  lib-label-selector-matches = check "matches" [
    (matches { } labels)
    (matches { matchLabels.team = "apps"; } labels)
    (!matches { matchLabels.team = "platform"; } labels)
    (!matches { matchLabels.env = "prod"; } labels)
    (matches {
      matchExpressions = [
        {
          key = "team";
          operator = "In";
          values = [
            "apps"
            "data"
          ];
        }
        {
          key = "env";
          operator = "DoesNotExist";
        }
      ];
    } labels)
    (
      !matches {
        matchExpressions = [
          {
            key = "tier";
            operator = "NotIn";
            values = [ "web" ];
          }
        ];
      } labels
    )
    (matches {
      matchExpressions = [
        {
          key = "env";
          operator = "NotIn";
          values = [ "prod" ];
        }
      ];
    } labels)
    (matches {
      matchExpressions = [
        {
          key = "tier";
          operator = "Exists";
        }
      ];
    } labels)
    # Both parts must hold.
    (
      !matches {
        matchLabels.team = "apps";
        matchExpressions = [
          {
            key = "tier";
            operator = "In";
            values = [ "db" ];
          }
        ];
      } labels
    )
  ];

  lib-label-selector-unknown-operator-throws =
    !(builtins.tryEval (
      matches {
        matchExpressions = [
          {
            key = "team";
            operator = "Equals";
          }
        ];
      } labels
    )).success;

  lib-label-selector-is-empty = check "isEmpty" [
    (isEmpty { })
    (isEmpty {
      matchLabels = { };
      matchExpressions = [ ];
    })
    (!isEmpty { matchLabels.team = "apps"; })
    (
      !isEmpty {
        matchExpressions = [
          {
            key = "team";
            operator = "Exists";
          }
        ];
      }
    )
  ];

  lib-label-selector-describe =
    let
      got = describe {
        matchLabels.team = "apps";
        matchExpressions = [
          {
            key = "tier";
            operator = "In";
            values = [
              "web"
              "api"
            ];
          }
          {
            key = "zone";
            operator = "NotIn";
            values = [ "a" ];
          }
          {
            key = "canary";
            operator = "Exists";
          }
          {
            key = "legacy";
            operator = "DoesNotExist";
          }
        ];
      };
    in
    got == "team=apps, tier in (web, api), zone notin (a), canary, !legacy" || throw "describe: ${got}";

  # Helm charts can render both fields as null.
  lib-label-selector-null-fields =
    isEmpty {
      matchLabels = null;
      matchExpressions = null;
    }
    && matches { matchLabels = null; } labels;
}
