# Tests for the `observedGeneration` and `pendingRestart` keys of a
# readiness declaration, and for the `readiness` argument of `scope.mkCR`,
# which replaces the kind's rule for one custom resource.

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

  running = {
    path = "/status/printableStatus";
    equals = "Running";
  };

  # A package that references a Widget CRD with the kind's readiness `kind`
  # and builds one Widget with the arguments `cr`.
  widgetPackage = kind: cr: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        widgetCrd = scope.mkCRDRef {
          group = "example.com";
          kind = "Widget";
          plural = "widgets";
          version = "v1";
          readiness = kind;
        };
        widget = scope.mkCR self.widgetCrd ({ name = "w"; } // cr);
        root = self.widget;
      };
  };

  build =
    kind: cr:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = widgetPackage kind cr;
      }
    ];

  widgetOf = kind: cr: byName "w" (manifests (build kind cr));

  annotationOf =
    kind: cr:
    let
      raw = ((widgetOf kind cr).metadata.annotations or { }).${kixKeys.readiness} or null;
    in
    if raw == null then null else builtins.fromJSON raw;

  refusedForKind = kind: evalFails (build kind { });
  refusedForCR = readiness: evalFails (build running { inherit readiness; });
in
{
  # Each new key passes through, and an empty hint or message is dropped.
  lib-readiness-generation-accepted-shapes =
    let
      pointer = validate (running // { observedGeneration = "/status/desiredGeneration"; });
      none = validate (running // { observedGeneration = false; });
      condition = validate (
        running
        // {
          pendingRestart = {
            condition = {
              type = "RestartRequired";
              status = "True";
            };
            hint = "Restart it.";
          };
        }
      );
      conditionNoHint = validate (
        running
        // {
          pendingRestart = {
            condition = {
              type = "RestartRequired";
              status = "True";
              reason = null;
            };
            hint = null;
          };
        }
      );
      path = validate (
        running
        // {
          pendingRestart = {
            path = "/status/restartPending";
            equals = "true";
            message = "/status/restartReason";
          };
        }
      );
      expected = {
        pointer = running // {
          observedGeneration = "/status/desiredGeneration";
        };
        none = running // {
          observedGeneration = false;
        };
        condition = running // {
          pendingRestart = {
            condition = {
              type = "RestartRequired";
              status = "True";
            };
            hint = "Restart it.";
          };
        };
        conditionNoHint = running // {
          pendingRestart.condition = {
            type = "RestartRequired";
            status = "True";
          };
        };
        path = running // {
          pendingRestart = {
            path = "/status/restartPending";
            equals = "true";
            message = [ "/status/restartReason" ];
          };
        };
      };
      got = {
        inherit
          pointer
          none
          condition
          conditionNoHint
          path
          ;
      };
    in
    (got == expected && validate condition == condition)
    || throw "unexpected normalization: ${builtins.toJSON got}";

  # A malformed new key fails the build of the package that declares it.
  lib-readiness-generation-refused-shapes =
    let
      bad = [
        # Not a JSON pointer.
        { observedGeneration = "status.desiredGeneration"; }
        # true has no meaning: the default already reads a field.
        { observedGeneration = true; }
        { observedGeneration = 1; }
        # A condition without a status.
        { pendingRestart.condition.type = "RestartRequired"; }
        # A failed entry's `rejected` has no meaning here.
        {
          pendingRestart = {
            path = "/status/phase";
            equals = "RestartPending";
            rejected = true;
          };
        }
        # An unknown key.
        {
          pendingRestart = {
            condition = {
              type = "RestartRequired";
              status = "True";
            };
            message = "/status/x";
          };
        }
        # A hint that is not a string.
        {
          pendingRestart = {
            condition = {
              type = "RestartRequired";
              status = "True";
            };
            hint = [ "Restart it." ];
          };
        }
        # A list where one state is expected.
        {
          pendingRestart = [
            {
              condition = {
                type = "RestartRequired";
                status = "True";
              };
            }
          ];
        }
      ];
      results = map (extra: refusedForKind (running // extra)) bad;
    in
    (builtins.all lib.id results && !(refusedForKind running))
    || throw "readiness shapes refused: ${builtins.toJSON results} (expected every entry true)";

  # The new keys reach the annotation on every custom resource of the kind.
  lib-readiness-generation-kind-annotation =
    let
      kind = running // {
        observedGeneration = "/status/desiredGeneration";
        pendingRestart.condition = {
          type = "RestartRequired";
          status = "True";
        };
      };
    in
    annotationOf kind { } == kind || throw "annotation: ${builtins.toJSON (annotationOf kind { })}";

  # A custom resource's own readiness replaces the kind's, is normalized
  # like it, and leaves no `readiness` field in the manifest.
  lib-readiness-generation-mkcr-overrides-kind =
    let
      own = {
        path = "/status/printableStatus";
        equals = "Stopped";
        observedGeneration = false;
        pendingRestart = {
          condition = {
            type = "RestartRequired";
            status = "True";
          };
          hint = null;
        };
      };
      expected = removeAttrs own [ "pendingRestart" ] // {
        pendingRestart.condition = {
          type = "RestartRequired";
          status = "True";
        };
      };
      got = annotationOf running { readiness = own; };
      manifest = widgetOf running { readiness = own; };
    in
    (got == expected && !(manifest ? readiness)) || throw "mkCR readiness: ${builtins.toJSON got}";

  # A kind with no rule takes one from the custom resource alone, and a
  # resource that passes null keeps the kind's.
  lib-readiness-generation-mkcr-without-kind-rule =
    let
      alone = annotationOf null { readiness = running; };
      keeps = annotationOf running { readiness = null; };
      neither = annotationOf null { };
    in
    (alone == running && keeps == running && neither == null)
    || throw "mkCR readiness: ${builtins.toJSON { inherit alone keeps neither; }}";

  # A malformed readiness on one custom resource fails the build.
  lib-readiness-generation-mkcr-refuses-malformed =
    let
      results = map refusedForCR [
        { path = "/status/phase"; }
        "Running"
        (running // { observedGeneration = "desiredGeneration"; })
        (running // { pendingRestart = "RestartRequired"; })
      ];
    in
    builtins.all lib.id results || throw "mkCR readiness refused: ${builtins.toJSON results}";
}
