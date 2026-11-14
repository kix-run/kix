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

  warningPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "warning";
        };
        unused = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "unused";
        };
        root = self.cm;
      };
    warnings = _: [
      "plain"
      {
        message = "replicas will be removed.";
        option = "replicas";
        fix = "Leave it out.";
      }
    ];
  };
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

  # kix.fail throws, for packages and for cluster definitions. A record
  # needs a message.
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
    && fails (errors.text { errors = [ { fix = "y"; } ]; });

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

  # An object has a line of its own and keeps its fields in the JSON.
  lib-errors-object =
    let
      object = {
        kind = "Job";
        namespace = "shop";
        name = "migrate";
      };
      text = errors.text {
        errors = [
          {
            message = "m";
            inherit object;
          }
        ];
      };
    in
    lib.take 2 (lib.splitString "\n" text) == [
      "m"
      "Object: Job shop/migrate"
    ]
    && (lib.head (payloadOf text).errors).object == object
    || throw "object: ${text}";

  # A field in the wrong form is left out of the record, and the message
  # says why: an unknown field, an id that is no change record id, an option
  # with the `config.` prefix, a dependency or a package's meta as an
  # option, a path with spaces, a dependency path, a cluster option inside
  # an instance, and an object without a kind.
  lib-errors-setting-form =
    let
      refused =
        e:
        let
          r = lib.head (payloadOf (errors.text { errors = [ ({ message = "m"; } // e) ]; })).errors;
        in
        lib.hasPrefix "m\nKix omitted an invalid field from this diagnostic: " r.message
        && builtins.all (n: !(r ? ${n})) (builtins.attrNames e);
    in
    refused { fixes = "y"; }
    && refused { id = "[K0001]"; }
    && refused { option = "config.tls.secretName"; }
    && refused { option = "deps.database"; }
    && refused { option = "meta.podSecurity"; }
    && refused { option = "the extraSpec"; }
    && refused { dependency = "deps.database"; }
    && refused { clusterOption = "instances.shop.db.config.password"; }
    && refused { object.name = "web"; }
    && !refused {
      option = "tls.secretName";
      dependency = "database";
      clusterOption = "cluster.domain";
      object = {
        kind = "Deployment";
        name = "web";
      };
    };

  # An error with a field in the wrong form keeps its place in the list, so
  # the other errors still show.
  lib-errors-bad-field-keeps-the-list =
    let
      text = errors.text {
        cluster = "prod";
        errors = [
          {
            message = "first";
            option = "config.x";
          }
          {
            message = "second";
            id = "[K0001]";
          }
          { message = "third"; }
        ];
      };
      payload = payloadOf text;
      messages = map (e: e.message) payload.errors;
    in
    (
      builtins.length messages == 3
      && lib.hasPrefix "first\n" (builtins.elemAt messages 0)
      && lib.hasInfix "starts with `config.`" (builtins.elemAt messages 0)
      && !((builtins.elemAt payload.errors 0) ? option)
      && lib.hasInfix "is not a change ID" (builtins.elemAt messages 1)
      && !((builtins.elemAt payload.errors 1) ? id)
      && builtins.elemAt messages 2 == "third"
    )
    || throw "bad field in a list: ${text}";

  # A warning is a record with the fields an error takes, and gains the
  # instance unless it sets one. A field in the wrong form stops the build,
  # as it does for kix.fail.
  lib-errors-warning-records =
    errors.warning "shop/db" "m" == {
      instance = "shop/db";
      message = "m";
    }
    &&
      errors.warning null {
        message = "m";
        clusterOption = "cluster.domain";
      } == {
        message = "m";
        clusterOption = "cluster.domain";
      }
    &&
      errors.warning "shop/db" {
        instance = "shop/other";
        message = "m";
      } == {
        instance = "shop/other";
        message = "m";
      }
    && fails (
      errors.warning "shop/db" {
        message = "m";
        id = "K1";
      }
    )
    && fails (
      errors.warning "shop/db" {
        message = "m";
        severity = "high";
      }
    );

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

  # The warnings a package raises reach the file the CLI reads as records
  # with the instance, and a structural warning names its object.
  lib-errors-package-warnings-in-file =
    let
      cluster = mkCluster [ { instances.app.web.package = warningPackage; } ];
      listed = builtins.fromJSON (builtins.readFile cluster.activationFiles.warnings);
      ofWeb = builtins.filter (w: (w.instance or null) == "app/web") listed;
    in
    (
      builtins.elem {
        instance = "app/web";
        message = "plain";
      } ofWeb
      && builtins.elem {
        instance = "app/web";
        message = "replicas will be removed.";
        option = "replicas";
        fix = "Leave it out.";
      } ofWeb
      && builtins.any (
        w:
        (w.object or null) == {
          kind = "ConfigMap";
          name = "unused";
        }
      ) ofWeb
    )
    || throw "package warnings: ${builtins.toJSON listed}";
}
