# Tests for the `failed` list of a readiness declaration: the shapes
# `validateReadiness` accepts and refuses, and the `kix.run/readiness`
# annotation that custom resources built through the typed chain carry.

{
  lib,
  k8s,
  kixKeys,
  mkCluster,
  manifests,
  byName,
  evalFails,
  ...
}:

let
  validate = k8s.validateReadiness "test" "example.com/Widget";

  validForm.condition = {
    type = "Valid";
    status = "True";
  };

  # A package that references a Widget CRD with the given readiness and
  # builds one Widget.
  widgetPackage = readiness: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        widgetCrd = scope.mkCRDRef {
          group = "example.com";
          kind = "Widget";
          plural = "widgets";
          version = "v1";
          inherit readiness;
        };
        widget = scope.mkCR self.widgetCrd { name = "w"; };
        root = self.widget;
      };
  };

  build =
    readiness:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = widgetPackage readiness;
      }
    ];

  annotationOf =
    readiness:
    ((byName "w" (manifests (build readiness))).metadata.annotations or { }).${kixKeys.readiness}
      or null;

  refused = readiness: evalFails (build readiness);
in
{
  # Each accepted shape normalizes to the keys the deploy compares: a null
  # reason is dropped, and an empty list leaves the declaration as it was.
  lib-readiness-failed-accepted-shapes =
    let
      conditionList = validate (
        validForm
        // {
          failed = [
            {
              condition = {
                type = "Valid";
                status = "False";
              };
            }
            {
              condition = {
                type = "Accepted";
                status = "False";
                reason = "Invalid";
              };
            }
            {
              condition = {
                type = "Accepted";
                status = "False";
                reason = null;
              };
            }
          ];
        }
      );
      pathList = validate {
        path = "/status/phase";
        equals = "Completed";
        failed = [
          {
            path = "/status/phase";
            equals = "Failed";
          }
        ];
      };
      pathExtras = validate {
        path = "/status/phase";
        equals = "Completed";
        failed = [
          {
            path = "/status/phase";
            equals = "FailedValidation";
            rejected = true;
            message = "/status/validationErrors";
          }
          {
            path = "/status/phase";
            equals = "Failed";
            rejected = false;
            hint = "Create it again.";
            message = [
              "/status/failureReason"
              "/status/message"
            ];
          }
        ];
      };
      notEqualsList = validate {
        path = "/status/updateStatus";
        notEquals = "failed";
        failed = [
          {
            path = "/status/updateStatus";
            equals = "failed";
          }
        ];
      };
      empty = validate (validForm // { failed = [ ]; });
      expectedConditionList = validForm // {
        failed = [
          {
            condition = {
              type = "Valid";
              status = "False";
            };
          }
          {
            condition = {
              type = "Accepted";
              status = "False";
              reason = "Invalid";
            };
          }
          {
            condition = {
              type = "Accepted";
              status = "False";
            };
          }
        ];
      };
    in
    (
      conditionList == expectedConditionList
      &&
        pathList.failed == [
          {
            path = "/status/phase";
            equals = "Failed";
          }
        ]
      &&
        notEqualsList.failed == [
          {
            path = "/status/updateStatus";
            equals = "failed";
          }
        ]
      &&
        pathExtras.failed == [
          {
            path = "/status/phase";
            equals = "FailedValidation";
            rejected = true;
            message = [ "/status/validationErrors" ];
          }
          {
            path = "/status/phase";
            equals = "Failed";
            hint = "Create it again.";
            message = [
              "/status/failureReason"
              "/status/message"
            ];
          }
        ]
      && empty == validForm
      && validate null == null
      && validate validForm == validForm
    )
    || throw "unexpected normalization: ${
      builtins.toJSON {
        inherit
          conditionList
          pathList
          notEqualsList
          empty
          ;
      }
    }";

  # A `failed` list that is not a list, or holds an entry of another shape,
  # fails the build of the package that declares it.
  lib-readiness-failed-refused-shapes =
    let
      bad = [
        # Not a list.
        {
          condition = {
            type = "Valid";
            status = "False";
          };
        }
        # A condition without a status.
        [ { condition.type = "Valid"; } ]
        # A reason that is not a string.
        [
          {
            condition = {
              type = "Valid";
              status = "False";
              reason = 1;
            };
          }
        ]
        # An unknown key on the entry.
        [
          {
            condition = {
              type = "Valid";
              status = "False";
            };
            message = "x";
          }
        ]
        # notEquals is a ready rule, not a failure state.
        [
          {
            path = "/status/phase";
            notEquals = "Failed";
          }
        ]
        # A path that is not a JSON pointer.
        [
          {
            path = "status.phase";
            equals = "Failed";
          }
        ]
        # A string where an entry is expected.
        [ "Failed" ]
        # A message that is not a JSON pointer.
        [
          {
            path = "/status/phase";
            equals = "Failed";
            message = "status.failureReason";
          }
        ]
        # A rejected flag that is not a boolean.
        [
          {
            path = "/status/phase";
            equals = "Failed";
            rejected = "yes";
          }
        ]
        # A hint that is not a string.
        [
          {
            path = "/status/phase";
            equals = "Failed";
            hint = [ "Create it again." ];
          }
        ]
        # An empty message list.
        [
          {
            path = "/status/phase";
            equals = "Failed";
            message = [ ];
          }
        ]
      ];
      results = map (failed: refused (validForm // { inherit failed; })) bad;
    in
    (builtins.all lib.id results && !(refused validForm))
    || throw "readiness.failed shapes refused: ${builtins.toJSON results} (expected every entry true)";

  # A `failed` key beside a ready rule of a shape Kix does not know fails
  # like any other malformed declaration.
  lib-readiness-failed-needs-a-ready-rule =
    refused {
      failed = [
        {
          condition = {
            type = "Valid";
            status = "False";
          };
        }
      ];
    }
    || throw "a declaration with only `failed` was accepted";

  # The annotation on a custom resource carries the ready rule and the
  # `failed` list, and stays unchanged without one.
  lib-readiness-failed-annotation =
    let
      withFailed = annotationOf (
        validForm
        // {
          failed = [
            {
              condition = {
                type = "Valid";
                status = "False";
                reason = null;
              };
            }
          ];
        }
      );
      without = annotationOf validForm;
    in
    (
      withFailed
      == ''{"condition":{"status":"True","type":"Valid"},"failed":[{"condition":{"status":"False","type":"Valid"}}]}''
      && without == ''{"condition":{"status":"True","type":"Valid"}}''
    )
    || throw "unexpected annotations: with failed ${toString withFailed}, without ${toString without}";
}
