+++
kind = "error"
id = "K6746"
library = ["scope.mkSecret"]
packages = ["secret"]
+++
Rewrite any SOPS file passed to `scope.mkSecret` or `packages.secret` that
contains a nested map, a list, or `null` as a flat YAML or JSON key-value map
(local deploys also accept dotenv; bundles do not). Every top-level value must
be a string, a number, `true`, or `false`. Kix writes numbers and booleans as
strings; store JSON meant for a single key as a string. Do not use INI files,
because `sops` decrypts them into section maps such as `DEFAULT`. To convert a
Kubernetes Secret manifest encrypted for Flux, extract `stringData` with
`sops decrypt --extract '["stringData"]'` (or base64-decode `data`), then
re-encrypt the file under a `.sops.yaml` rule with no `encrypted_regex`,
because `encrypted_regex: ^(data|stringData)$` leaves flat keys in plain text.
Earlier releases wrote maps and lists as JSON text and `null` as `"null"`,
which caused a Flux manifest to add `apiVersion`, `kind`, `metadata`,
`stringData`, and `type` keys to the live Secret. Delete those keys from the
live Secret manually, because Kix does not remove keys from `data`. `kix plan`,
`kix deploy`, and `kix rollback` now refuse a top-level map, list, or `null`
with `[K6746]` and name the offending key. This check runs in the
cluster-connected dry run only for Secrets about to be applied: on first
deploy, when the Secret or its SOPS file changed, or with `--reconcile`.
Unchanged Secrets are skipped, and `kix check`, `kix build`,
`kix plan --offline`, and `kix plan --read-only` do not run this check. Local
builds check the decrypted file, while `kix plan --bundle` checks the encrypted
file without decrypting it. Plans title the refusal "its SOPS file has a nested
or empty value" (`sops_not_flat` in `kix plan --out` plan files). With the
default `--on-error stop`, the deploy stops before applying anything.
`kix deploy --on-error continue` leaves this Secret unchanged, skips resources
that depend on it, and applies the rest. `kix rollback` has no
`--on-error continue` and refuses builds created before the file was converted:
roll back to a newer deployment record, or check out the target commit, convert
its file, and run `kix deploy`.
