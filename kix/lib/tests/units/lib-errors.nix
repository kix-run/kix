# Tests for kix.fail, scope.fail, and the cluster's problem list
# (core/error.nix, meta.nix).

{
  lib,
  kixlib,
  publicKix,
  mkCluster,
  evalFails,
  ...
}:

let
  errors = import ../../core/error.nix { inherit lib; };
  meta = import ../../meta.nix { inherit lib; };

  # Return the JSON that follows the marker on the last line of `text`.
  payloadOf =
    text:
    let
      last = lib.last (lib.splitString "\n" text);
    in
    assert lib.hasPrefix errors.marker last;
    builtins.fromJSON (lib.removePrefix errors.marker last);

  fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;

  full = {
    id = "K0001";
    instance = "shop/db";
    package = "cnpg-database";
    option = "password";
    message = "the \"password\" option was removed.\nIt kept the password in plain text.";
    fix = "Set this line:\n  deps.password = ref.shop.db-login;";
  };

  failingPackage = {
    meta.version = "test";
    build =
      { scope, ... }:
      {
        root = scope.fail {
          message = "no";
          fix = "yes";
        };
      };
  };

  assertingPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "asserting";
        };
        root = self.cm;
      };
    assertions = _: [
      {
        assertion = false;
        message = "replicas was removed.";
        id = "K0002";
        fix = "Set config.replicas.";
      }
      {
        assertion = true;
        message = "never shown";
      }
    ];
  };
  asserting = mkCluster [ { instances.app.web.package = assertingPackage; } ];
in
{
  # One error: the id, the instance, the package, the message, the option,
  # and the fix for a person, then the marker line for Kix.
  lib-errors-one-error-text =
    let
      text = errors.text { errors = [ full ]; };
      lines = lib.splitString "\n" text;
    in
    lib.take 6 lines == [
      "[K0001] shop/db (cnpg-database): the \"password\" option was removed."
      "It kept the password in plain text."
      "Option: password"
      "Fix: Set this line:"
      "  deps.password = ref.shop.db-login;"
      (lib.elemAt lines 5)
    ]
    && builtins.length lines == 6
    || throw "one error: ${text}";

  # The JSON keeps quotes and newlines, so Kix reads back the same fields.
  lib-errors-json-round-trips =
    payloadOf (errors.text { errors = [ full ]; }) == { errors = [ full ]; };

  # A message alone is the whole error, and null fields are left out.
  lib-errors-message-alone =
    let
      text = errors.text {
        errors = [
          {
            message = "boom";
            fix = null;
          }
        ];
      };
    in
    lib.head (lib.splitString "\n" text) == "boom"
    &&
      payloadOf text == {
        errors = [ { message = "boom"; } ];
      };

  # A list names the cluster and its problems, each under a dash.
  lib-errors-problem-list =
    let
      text = errors.text {
        cluster = "prod";
        errors = [
          (errors.fromAssertion "shop/db" {
            assertion = false;
            message = "m1";
            fix = "f1\nf2";
            id = "K0001";
          })
          { message = "m2"; }
        ];
      };
    in
    lib.take 5 (lib.splitString "\n" text) == [
      "cluster 'prod' has 2 problems:"
      "  - [K0001] shop/db: m1"
      "    Fix: f1"
      "    f2"
      "  - m2"
    ]
    &&
      payloadOf text == {
        cluster = "prod";
        errors = [
          {
            id = "K0001";
            instance = "shop/db";
            message = "m1";
            fix = "f1\nf2";
          }
          { message = "m2"; }
        ];
      };

  # kix.fail throws, for packages and for cluster definitions, and refuses a
  # field it does not take, a missing message, and an id in brackets.
  lib-errors-fail-throws =
    fails (kixlib.fail "boom")
    && fails (
      kixlib.fail [
        "a"
        { message = "b"; }
      ]
    )
    && fails (kixlib.fail [ ])
    && fails (publicKix.fail { message = "boom"; })
    && fails (
      errors.text {
        errors = [
          {
            message = "x";
            fixes = "y";
          }
        ];
        strict = true;
      }
    )
    && fails (errors.text { errors = [ { fix = "y"; } ]; })
    && fails (
      errors.text {
        errors = [
          {
            message = "x";
            id = "[K0001]";
          }
        ];
      }
    )
    && !fails (
      errors.text {
        errors = [
          {
            message = "x";
            fixes = "y";
          }
        ];
      }
    );

  # A dependency and a cluster option each have a line of their own.
  lib-errors-dependency-and-cluster-option =
    let
      text = errors.text {
        errors = [
          {
            instance = "kube-system/cilium";
            dependency = "platform-cilium";
            clusterOption = "cluster.roles.cni.binding";
            message = "m";
          }
        ];
      };
    in
    lib.take 3 (lib.splitString "\n" text) == [
      "kube-system/cilium: m"
      "Dependency: platform-cilium"
      "Cluster option: cluster.roles.cni.binding"
    ]
    || throw "dependency and cluster option: ${text}";

  # kix.fail refuses a setting written in another form: an option with the
  # `config.` prefix, a dependency or a package's meta as an option, a path
  # with spaces, a dependency path, and a cluster option inside an instance.
  lib-errors-setting-form =
    let
      refused = e: fails (errors.text { errors = [ ({ message = "m"; } // e) ]; });
    in
    refused { option = "config.tls.secretName"; }
    && refused { option = "deps.database"; }
    && refused { option = "meta.podSecurity"; }
    && refused { option = "the extraSpec"; }
    && refused { dependency = "deps.database"; }
    && refused { clusterOption = "instances.shop.db.config.password"; }
    && !refused {
      option = "tls.secretName";
      dependency = "database";
      clusterOption = "cluster.domain";
    };

  # scope.fail stops the build of the instance that calls it.
  lib-errors-scope-fail = evalFails (mkCluster [ { instances.app.bad.package = failingPackage; } ]);

  # A failed assertion keeps its fields and gains the instance that raised
  # it. The message no longer starts with the instance name. A cluster with a
  # failed assertion does not build.
  lib-errors-assertion-fields =
    let
      combined = meta.combineDiagnostics {
        instanceName = "web";
        namespaceName = "app";
        metaResult = {
          warnings = [ ];
          assertions = [ ];
        };
        packageResult = {
          warnings = [ ];
          assertions = assertingPackage.assertions { };
        };
        structuralWarnings = [ ];
      };
    in
    combined.failedAssertions == [
      {
        assertion = false;
        instance = "app/web";
        message = "replicas was removed.";
        id = "K0002";
        fix = "Set config.replicas.";
      }
    ]
    && evalFails asserting
    || throw "assertions: ${builtins.toJSON combined.failedAssertions}";
}
