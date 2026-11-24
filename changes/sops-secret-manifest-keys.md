+++
kind = "error"
id = "K6746"
library = ["scope.mkSecret"]
+++
If a SOPS file passed to `scope.mkSecret` (or `packages.secret`) has a
top-level map, list, or `null` value, rewrite it as a flat key-value map where
every value is text, a number, `true`, or `false`. If a key is meant to hold
JSON, store that JSON as a string instead. To convert a Kubernetes Secret
manifest encrypted for Flux, extract its plain-text keys with `sops decrypt
--extract '["stringData"]'` (or base64-decode its `data` entries) and
re-encrypt the result using a `.sops.yaml` creation rule without
`encrypted_regex`. Flux's usual `encrypted_regex: ^(data|stringData)$` rule
leaves a flat file's values in plain text. `kix deploy` now stops before
applying the Secret, and `kix plan` refuses the file too (on a bundle, without
decrypting it), reporting `[K6746]` and naming the key. Numbers, `true`, and
`false` are still accepted and written as text. Earlier releases wrote maps and
lists as JSON text and `null` as `"null"`, so a Flux file deployed keys such as
`apiVersion`, `kind`, `metadata`, `stringData`, and `type` onto the Secret. If
an earlier deploy wrote those keys to a live Secret, remove them in the
cluster, because Kix does not delete existing keys from a Secret's `data`.
