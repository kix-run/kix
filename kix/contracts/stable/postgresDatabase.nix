# Define the PostgreSQL `database` contract for packages that answer the
# `database` alias and publish connection details on `root.out`
# (`kix.contracts.postgresDatabase`).
#
# Provider packages call `check`, which requires every field. Consumers
# validate their `database` dependency with `assertions`, which requires only
# the `required` fields so a `kix.mkImport` stand-in only needs to publish the
# connection fields.
{
  lib,
  mkContract,
  credentialsField,
  ...
}:
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
      shape = "the PostgreSQL hostname, such as a Service FQDN or an RDS endpoint";
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
    credentials = credentialsField { keys = credentialKeys; };
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
in
mkContract {
  name = "Postgres database";
  alias = "database";
  inherit fields;
}
