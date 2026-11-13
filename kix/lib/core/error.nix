# Build the errors the Kix library raises for a person to fix.
#
# An error is plain text for a person, followed by one last line that starts
# with `kix-error/1 ` and holds the same errors as JSON. Kix reads that line
# and shows each error from its fields, without a stack trace. A person who
# runs Nix directly reads the text above it. `cli/kix-core/src/eval/library_error.rs`
# reads the line, so change the two together.
{ lib }:
let
  marker = "kix-error/1 ";

  # The fields an error may set. Only `message` is required.
  fields = [
    "id"
    "instance"
    "package"
    "option"
    "dependency"
    "clusterOption"
    "message"
    "fix"
  ];

  plain = v: builtins.unsafeDiscardStringContext (toString v);

  # Return why `record` names its setting in the wrong form, or null. A path
  # holds no spaces. `option` is a path in the instance's `config`, so it
  # does not start with `config.`. A dependency goes in `dependency` and a
  # package's `meta` is no setting of the instance. `clusterOption` is a path
  # in the cluster definition, and a path into an instance goes in `option`
  # or `dependency`.
  badSetting =
    record:
    let
      option = record.option or "";
      clusterOption = record.clusterOption or "";
      prefix = lib.findFirst (p: lib.hasPrefix "${p}." option) null [
        "config"
        "deps"
        "meta"
      ];
    in
    if builtins.match ".*[[:space:]].*" (option + clusterOption) != null then
      "`option` and `clusterOption` are paths and have no spaces."
    else if prefix == "config" then
      "option \"${option}\" starts with `config.`. Write the path in the instance's config: \"${lib.removePrefix "config." option}\"."
    else if prefix == "deps" then
      "option \"${option}\" names a dependency. Write dependency = \"${lib.removePrefix "deps." option}\"."
    else if prefix == "meta" then
      "option \"${option}\" is a field of the package's meta, which is no setting of the instance. Leave `option` out."
    else if
      record ? dependency && builtins.match "[A-Za-z_][A-Za-z0-9_'-]*" record.dependency == null
    then
      "dependency \"${record.dependency}\" is not the name of a dependency. Write the name alone, such as \"database\"."
    else if lib.hasPrefix "instances." clusterOption then
      "clusterOption \"${clusterOption}\" is inside an instance. Set `instance`, and write the path in its config as `option` or the dependency as `dependency`."
    else
      null;

  # Return `e` as an error record with only string fields. A string is the
  # message. `strict` refuses fields outside `fields`.
  toRecord =
    strict: e:
    let
      r = if builtins.isString e then { message = e; } else e;
      unknown = lib.subtractLists fields (builtins.attrNames r);
      record = lib.mapAttrs (_: plain) (lib.filterAttrs (n: v: v != null && builtins.elem n fields) r);
    in
    if !builtins.isAttrs r then
      throw "kix.fail takes a message or an attribute set with `message`, and got a ${builtins.typeOf r}."
    else if strict && unknown != [ ] then
      throw "kix.fail does not take ${lib.concatMapStringsSep ", " (n: "`${n}`") unknown}. It takes ${
        lib.concatMapStringsSep ", " (n: "`${n}`") fields
      }."
    else if (r.message or null) == null then
      throw "kix.fail needs a `message`."
    else if record ? id && builtins.match "K[0-9]{4}" record.id == null then
      throw "kix.fail: id \"${record.id}\" is not a change record id. Write `K` and four digits, such as \"K0001\"."
    else if badSetting record != null then
      throw "kix.fail: ${badSetting record}"
    else
      record;

  indent = prefix: text: lib.concatStringsSep "\n${prefix}" (lib.splitString "\n" text);

  # Return the first line of an error for a person: the id, where, and the
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

  # Return one error as text, its later lines indented by `prefix`.
  describe =
    prefix: r:
    indent prefix (
      headline r
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
in
rec {
  inherit marker fields;

  # Return the text `failAll` throws for `errors`, for tests and for code
  # that shows an error without stopping. `strict` refuses fields that
  # `kix.fail` does not take.
  text =
    {
      errors,
      cluster ? null,
      strict ? false,
    }:
    render {
      errors = map (toRecord strict) errors;
      cluster = if cluster == null then null else plain cluster;
    };

  # Stop evaluation with an error for a person to fix. `e` is a message, or
  # `{ message; fix ? null; id ? null; instance ? null; package ? null;
  # option ? null; dependency ? null; clusterOption ? null; }`, or a list of
  # them to report several at once. `id` is the change record id, such as
  # "K0001". The last three name what to change. `option` is a path in the
  # instance's `config`, such as "tls.secretName". `dependency` is the name
  # of one of the instance's `deps`. `clusterOption` is a path in the cluster
  # definition, such as "cluster.domain".
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
      strict = true;
    });

  # Stop evaluation with every error in `errors` at once. `cluster` names the
  # cluster they belong to, or is null. An error may carry fields `kix.fail`
  # does not take, which are left out.
  failAll = args: throw (text args);

  # Return `scope.fail` for an instance: `fail` with `instance` set to
  # "<namespace>/<name>" on every error that does not set it.
  failFor =
    instance: e:
    let
      withInstance = e: { inherit instance; } // (if builtins.isString e then { message = e; } else e);
    in
    fail (if builtins.isList e then map withInstance e else withInstance e);

  # Return the error record of a failed assertion: its error fields, with
  # `instance` set unless it sets one. Other fields are dropped.
  fromAssertion =
    instance: a:
    lib.optionalAttrs (instance != null) { inherit instance; }
    // builtins.intersectAttrs (lib.genAttrs fields (_: null)) a;
}
