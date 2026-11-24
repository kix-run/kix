+++
kind = "error"
id = "K9044"
+++
`kix deploy` and `kix plan` now send a Secret's values under `data`, base64-encoded, instead of under `stringData`, so Kix owns each key of the live Secret. A key you remove from the build or from its SOPS file is now removed from the cluster, where before it stayed. `kix status` now reports a Secret key that someone changed on the cluster. When another field manager has changed a key that the build sets, for example with `kubectl edit`, the deploy now stops with a field ownership conflict instead of overwriting the value; when the apply itself is refused, the error starts with `[K9044]`. Run the deploy with `--force-conflicts` to write the build's values, or put the other value in the build.
