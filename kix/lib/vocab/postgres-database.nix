# Define the PostgreSQL `database` contract for packages that answer the
# `database` alias and publish connection details on `root.out`
# (`kix.contracts.postgresDatabase`).
#
# Provider packages call `check`, which requires every field. Consumers
# validate their `database` dependency with `assertions`, which requires only
# the `required` fields so a `kix.mkImport` stand-in only needs to publish the
# connection fields.
{ lib }:
let
  isString = builtins.isString;

  # Accept either a plain extension name or `{ name; version; }`.
  isExtension = e: isString e || (builtins.isAttrs e && isString (e.name or null));

  # Consumers read credentials via `keyRef "username"` and `keyRef "password"`.
  # Secrets with no declared `out.keys` (such as untracked secrets) pass
  # without key verification.
  credentialKeys = [
    "username"
    "password"
  ];

  fields = {
    host = {
      required = true;
      shape = "the PostgreSQL Service FQDN";
      test = isString;
    };
    # Kept as a string because consumers interpolate it into URLs and
    # environment variables.
    port = {
      required = true;
      shape = "the PostgreSQL port as a string (pass an integer through toString)";
      test = isString;
    };
    database = {
      required = true;
      shape = "the database name";
      test = isString;
    };
    credentials = {
      required = true;
      shape = "a Secret instance (out.keyRef) with the keys ${lib.concatStringsSep " and " credentialKeys}";
      test =
        v:
        let
          out = if builtins.isAttrs v then v.out or { } else { };
          keys = out.keys or null;
        in
        builtins.isFunction (out.keyRef or null)
        && (!builtins.isList keys || lib.all (k: builtins.elem k keys) credentialKeys);
    };
    username = {
      required = false;
      shape = "the role name";
      test = isString;
    };
    extensions = {
      required = false;
      shape = "a list of extension names or { name; version; } attrsets";
      test = v: builtins.isList v && lib.all isExtension v;
    };
    tls = {
      required = false;
      shape = "true or false for whether PostgreSQL serves TLS, or null when the provider cannot tell";
      test = v: v == null || builtins.isBool v;
    };
  };

  # Return a list of validation errors for `out`. When `all` is true, require
  # optional fields as well.
  problemsWith =
    all: out:
    builtins.concatMap (
      field:
      let
        f = fields.${field};
      in
      if !(out ? ${field}) then
        lib.optional (all || f.required) "${field} is missing (${f.shape})"
      else if !(f.test out.${field}) then
        [ "${field} is not ${f.shape}" ]
      else
        [ ]
    ) (builtins.attrNames fields);

  here = "kix/lib/vocab/postgres-database.nix";
in
{
  alias = "database";
  inherit fields;

  # Return the contract violations a consumer reports for `out`.
  problems = problemsWith false;

  # Validate a provider's `root.out` and return it, or throw if any field is
  # missing or malformed.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the Postgres database contract: ${lib.concatStringsSep "; " found} (${here})";

  # Return dependency assertions that validate `dep.out` against the contract.
  # Dependency assertions run after `build`, so missing attributes that `build`
  # evaluates directly will fail earlier with a missing-attribute error.
  assertions =
    who: dep:
    let
      found = problemsWith false (dep.out or { });
      meta = dep._meta or { };
      provider =
        if meta ? namespaceName && meta ? instanceName then
          "${meta.namespaceName}/${meta.instanceName}"
        else
          "the instance it resolved to";
    in
    lib.optional (found != [ ]) {
      assertion = false;
      message = "${who}: deps.database resolved to ${provider}, whose out does not honour the Postgres database contract: ${lib.concatStringsSep "; " found}. Set them on that instance's out (a kix.mkImport sets them in `out`), or wire another database with deps.database = ref.<ns>.<instance> (${here}).";
    };
}
