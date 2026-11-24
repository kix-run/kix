# Tests for the one label selector matcher (core/label-selector.nix).

{ lib, ... }:

let
  inherit (import ../../core/label-selector.nix { inherit lib; })
    matches
    isEmpty
    describe
    problems
    ;
  scorecard = import ../../scorecard.nix { inherit lib; };

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

  # A malformed selector matches nothing, and `problems` says why.
  lib-label-selector-problems =
    let
      bad = {
        matchExpressions = [
          {
            key = "team";
            operator = "Equals";
            values = [ "apps" ];
          }
          { operator = "Exists"; }
        ];
      };
      found = problems bad;
    in
    (
      !matches bad labels
      && builtins.length found == 2
      && lib.hasInfix "key 'team' sets operator 'Equals'" (builtins.head found)
      && problems { matchLabels.team = "apps"; } == [ ]
      && describe bad == "team Equals (apps), ?"
    )
    || throw "problems: ${builtins.toJSON found}, describe: ${describe bad}";

  # A finding's change record id reaches both the warning text and the
  # failed assertion.
  lib-label-selector-scorecard-finding-keeps-id =
    let
      finding = severity: {
        rule = "architecture.monitorSelectorMatchesService";
        inherit severity;
        namespace = "app";
        instance = null;
        resource = "ServiceMonitor/cache";
        message = "m";
        id = "K1895";
      };
      out = scorecard.scorecardToWarnings [
        (finding "warning")
        (finding "error")
      ];
    in
    (
      out.warnings
      == [ "[K1895] [scorecard:architecture.monitorSelectorMatchesService] app/ServiceMonitor/cache: m" ]
      && (builtins.head out.assertions).id == "K1895"
    )
    || throw "scorecard id: ${builtins.toJSON out}";

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
