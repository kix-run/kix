# Build the errors and warnings the Kix library gives a person to fix.
#
# An error and a warning are the same record. An error stops evaluation. A
# warning goes into the cluster's `diagnostics.warnings` and the build's
# `kix-warnings.json`, and the build goes on.
#
# A thrown error is plain text for a person, followed by one last line that
# starts with `kix-error/1 ` and holds the same errors as JSON. Kix reads that
# line and shows each error from its fields, without a stack trace. A person
# who runs Nix directly reads the text above it.
# `cli/kix-core/src/eval/library_record.rs` reads both the line and the
# warnings file, so change the two together.
{ lib }:
let
  marker = "kix-error/1 ";

  # The fields a record may set. Only `message` is required.
  fields = [
    "id"
    "instance"
    "package"
    "object"
    "option"
    "dependency"
    "clusterOption"
    "message"
    "fix"
  ];

  plain = v: builtins.unsafeDiscardStringContext (toString v);

  isPath = v: builtins.isString v && builtins.match ".*[[:space:]].*" v == null;

  # Return why `value` is not a valid `field`, or null. This function owns
  # the form of every field. `id` is a change record id. `option` is a path
  # in the instance's `config`, so it does not start with `config.`. A
  # dependency goes in `dependency`, and a package's `meta` is no setting of
  # the instance. `clusterOption` is a path in the cluster definition, and a
  # path into an instance goes in `option` or `dependency`. `object` names a
  # Kubernetes object by `kind`, `name`, and an optional `namespace`.
  fieldProblem =
    field: value:
    let
      text = plain value;
      prefix = lib.findFirst (p: lib.hasPrefix "${p}." text) null [
        "config"
        "deps"
        "meta"
      ];
      objectKeys = [
        "kind"
        "name"
        "namespace"
      ];
    in
    if !(builtins.elem field fields) then
      "it has a field `${field}`, which Kix does not take. Kix takes ${
        lib.concatMapStringsSep ", " (n: "`${n}`") fields
      }."
    else if field == "object" then
      if
        builtins.isAttrs value
        && value ? kind
        && value ? name
        && lib.subtractLists objectKeys (builtins.attrNames value) == [ ]
      then
        null
      else
        "object ${builtins.toJSON value} is not an object reference. Write { kind = \"Deployment\"; name = \"web\"; }, with an optional namespace."
    else if builtins.isAttrs value || builtins.isList value then
      "${field} is a ${builtins.typeOf value}. Write a string."
    else if field == "id" && builtins.match "K[0-9]{4}" text == null then
      "id \"${text}\" is not a change record id. Write `K` and four digits, such as \"K0001\"."
    else if
      builtins.elem field [
        "option"
        "clusterOption"
      ]
      && !(isPath text)
    then
      "${field} \"${text}\" is not an option path. Write a path without spaces."
    else if field == "option" && prefix == "config" then
      "option \"${text}\" starts with `config.`. Write the path in the instance's config: \"${lib.removePrefix "config." text}\"."
    else if field == "option" && prefix == "deps" then
      "option \"${text}\" names a dependency. Write dependency = \"${lib.removePrefix "deps." text}\"."
    else if field == "option" && prefix == "meta" then
      "option \"${text}\" is a field of the package's meta, which is not an instance option. Leave `option` out."
    else if field == "dependency" && builtins.match "[A-Za-z_][A-Za-z0-9_'-]*" text == null then
      "dependency \"${text}\" is not a valid dependency name. Write the name alone, such as \"database\"."
    else if field == "clusterOption" && lib.hasPrefix "instances." text then
      "clusterOption \"${text}\" is inside an instance. Set `instance`, and write the path in its config as `option` or the dependency as `dependency`."
    else
      null;

  # Return `e` as `{ record; problems; }`. A string is the message. `record`
  # keeps the fields that pass `fieldProblem`, with string values, and
  # `problems` says why each other field was left out.
  check =
    e:
    let
      r = if builtins.isString e then { message = e; } else e;
      given = lib.filterAttrs (_: v: v != null) r;
      problemOf = lib.mapAttrs fieldProblem given;
      good = lib.filterAttrs (n: _: problemOf.${n} == null) given;
    in
    if !builtins.isAttrs r then
      throw "kix.fail takes a message or an attribute set with `message`, and got a ${builtins.typeOf r}."
    else if !(given ? message) then
      throw "kix.fail needs a `message`."
    else
      {
        record = lib.mapAttrs (
          n: v:
          if n == "object" then lib.mapAttrs (_: plain) (lib.filterAttrs (_: x: x != null) v) else plain v
        ) good;
        problems = builtins.filter (p: p != null) (builtins.attrValues problemOf);
      };

  # Return `e` as an error record. A field in the wrong form is left out, and
  # the message says why, so one badly written error does not hide the
  # others it is reported with. Every caller treats such a field the same way.
  toRecord =
    e:
    let
      checked = check e;
    in
    if checked.problems == [ ] then
      checked.record
    else
      checked.record
      // {
        message =
          checked.record.message
          + "\nThe code that raised this passed a field in the wrong form, which Kix left out: "
          + lib.concatStringsSep " " checked.problems;
      };

  indent = prefix: text: lib.concatStringsSep "\n${prefix}" (lib.splitString "\n" text);

  objectText = o: "${o.kind} " + lib.optionalString (o ? namespace) "${o.namespace}/" + o.name;

  # Return the first line of a record for a person: the id, where, and the
  # message.
  headline =
    r:
    let
      where =
        if r ? instance then
          r.instance + lib.optionalString (r ? package) " (${r.package})"
        else
          r.package or null;
    in
    lib.optionalString (r ? id) "[${r.id}] "
    + lib.optionalString (where != null) "${where}: "
    + r.message;

  # Return one record as text, its later lines indented by `prefix`.
  describe =
    prefix: r:
    indent prefix (
      headline r
      + lib.optionalString (r ? object) "\nObject: ${objectText r.object}"
      + lib.optionalString (r ? option) "\nOption: ${r.option}"
      + lib.optionalString (r ? dependency) "\nDependency: ${r.dependency}"
      + lib.optionalString (r ? clusterOption) "\nCluster option: ${r.clusterOption}"
      + lib.optionalString (r ? fix) "\nFix: ${r.fix}"
    );

  # Return the text a failure throws: the errors for a person, then the
  # marker line for Kix.
  render =
    { errors, cluster }:
    let
      count = builtins.length errors;
      text =
        if count == 1 && cluster == null then
          describe "" (builtins.head errors)
        else
          "${if cluster == null then "There are" else "cluster '${cluster}' has"} ${toString count} problem${
            lib.optionalString (count != 1) "s"
          }:"
          + lib.concatMapStrings (r: "\n  - ${describe "    " r}") errors;
      payload = {
        inherit errors;
      }
      // lib.optionalAttrs (cluster != null) { inherit cluster; };
    in
    "${text}\n${marker}${builtins.toJSON payload}";

  withInstance =
    instance: e:
    lib.optionalAttrs (instance != null) { inherit instance; }
    // (if builtins.isString e then { message = e; } else e);
in
rec {
  inherit marker fields describe;

  # Return why `value` is not a valid `field` of a record, or null.
  inherit fieldProblem;

  # Return the text `failAll` throws for `errors`, for tests and for code
  # that shows an error without stopping.
  text =
    {
      errors,
      cluster ? null,
    }:
    render {
      errors = map toRecord errors;
      cluster = if cluster == null then null else plain cluster;
    };

  # Stop evaluation with an error for a person to fix. `e` is a message, or
  # `{ message; fix ? null; id ? null; instance ? null; package ? null;
  # object ? null; option ? null; dependency ? null; clusterOption ? null; }`,
  # or a list of them to report several at once. `id` is the change record
  # id, such as "K0001". `object` is the Kubernetes object at fault, as
  # `{ kind; name; namespace ? null; }`. The last three name what to change.
  # `option` is a path in the instance's `config`, such as "tls.secretName".
  # `dependency` is the name of one of the instance's `deps`. `clusterOption`
  # is a path in the cluster definition, such as "cluster.domain".
  fail =
    e:
    throw (text {
      errors =
        if e == [ ] then
          throw "kix.fail needs at least one error."
        else if builtins.isList e then
          e
        else
          [ e ];
    });

  # Stop evaluation with every error in `errors` at once. `cluster` names the
  # cluster they belong to, or is null.
  failAll = args: throw (text args);

  # Return `scope.fail` for an instance: `fail` with `instance` set to
  # "<namespace>/<name>" on every error that does not set it.
  failFor =
    instance: e:
    fail (if builtins.isList e then map (withInstance instance) e else withInstance instance e);

  # Return the error record of a failed assertion: its fields without
  # `assertion`, with `instance` set unless it sets one.
  fromAssertion = instance: a: withInstance instance (removeAttrs a [ "assertion" ]);

  # Return warning `w` as a record. `w` is a message or takes the fields
  # `kix.fail` takes. `instance` is set unless `w` sets one, and may be null
  # for a warning about the whole cluster. A field in the wrong form stops
  # evaluation with the same error `kix.fail` gives for it.
  warning =
    instance: w:
    let
      e = withInstance instance w;
      checked = check e;
    in
    if checked.problems == [ ] then checked.record else fail e;
}
