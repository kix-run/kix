# Package options that the secret-options test
# (kix/lib/tests/units/secret-options.nix) would take for a secret value,
# and that are not. Each entry is `"<package>.<option path>" = "<why>"`.
# A package takes every secret through a secret dependency; add an entry
# only for an option that holds no secret and no path to one.
{
  "secret.source" = "The secret package is a source package: it fills a Secret from this SOPS file.";
  "cnpg-cluster.backup.credentialKeys.secretAccessKey" =
    "The name of a key in the credentials dependency, not the key itself.";
  "cnpg-cluster.import.passwordKey" =
    "The name of a key in the importPassword dependency, not the password.";
  "stackgres-object-storage.credentialKeys.secretAccessKey" =
    "The name of a key in the storage credentials dependency, not the key itself.";
  "tempo.objectStorage.credentialKeys.secretAccessKey" =
    "The name of a key in the storage credentials dependency, not the key itself.";
  "filebrowser.tokenExpirationTime" = "How long a login session lasts.";
}
