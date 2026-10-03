# The Postgres `database` contract: what a package answering the `database`
# alias publishes on root.out, for one database and its role on a
# PostgreSQL server. A consumer written against these fields runs on any
# provider that honours them.
#
# A provider package passes its out through `check`, which requires every
# field. A consumer holds its dependency to the contract through
# `assertions`, which requires the fields marked `required` and checks the
# shape of the others when they are present, so a kix.mkImport stand-in may
# publish only the connection fields. Packages reach this file as
# `kix.contracts.postgresDatabase`.
{ lib }:
let
  isString = builtins.isString;

  # A name, or `{ name; version; }` as stackgres-database's `extensions`
  # option takes it.
  isExtension = e: isString e || (builtins.isAttrs e && isString (e.name or null));

  # Consumers read the role's login through keyRef "username" and
  # keyRef "password". A Secret without declared keys (an untracked one)
  # cannot be checked and passes.
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
    port = {
      required = true;
      shape = "the PostgreSQL port, as an integer or a string";
      test = v: builtins.isInt v || isString v;
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

  # Problems with `out`, one string per field. `all` requires every field;
  # otherwise only the required ones.
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

  # The problems a consumer's assertion reports for `out`.
  problems = problemsWith false;

  # For a provider: `root.out = kix.contracts.postgresDatabase.check who { ... }`.
  # Returns `out`, or throws naming every missing or misshapen field.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the Postgres database contract: ${lib.concatStringsSep "; " found} (${here})";

  # For a consumer:
  # `deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;`.
  # The message names the instance the dependency resolved to. Dependency
  # assertions are evaluated after the build, so a field the build reads
  # and `out` lacks fails first with Nix's missing-attribute error.
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
