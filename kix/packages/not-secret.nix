# Package options that the secret-options test
# (kix/lib/tests/units/secret-options.nix) would take for a secret value,
# and that are not. Each entry is `"<package>.<option path>" = "<why>"`.
# A package takes every secret through a secret dependency; add an entry
# only for an option that holds no secret and no path to one.
{
  "secret.source" = "The secret package is a source package: it fills a Secret from this SOPS file.";
  "cnpg-cluster.backup.credentialKeys.secretAccessKey" =
    "Names which key to read from the credentials dependency.";
  "cnpg-cluster.import.passwordKey" = "Names which key to read from the importPassword dependency.";
  "stackgres-object-storage.credentialKeys.secretAccessKey" =
    "Names which key to read from the storageCredentials dependency.";
  "tempo.objectStorage.credentialKeys.secretAccessKey" =
    "Names which key to read from the storageCredentials dependency.";
  "filebrowser.tokenExpirationTime" = "How long a login session lasts.";
}
