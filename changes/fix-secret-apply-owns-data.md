+++
kind = "error"
id = "K9044"
+++
If a deploy stops on a field ownership conflict for a Secret's `data` keys (in the plan, or with `[K9044]` during apply), run `kix deploy` with `--force-conflicts` to write the build's values. To keep the cluster's values instead, copy them into the build (`stringData` or the SOPS file) and deploy again. `kix deploy` and `kix plan` now send Secret values base64-encoded under `data` rather than `stringData`, so Kix owns each key on the live Secret. When another field manager such as `kubectl edit` changes a key that the build sets, Kix stops on a conflict instead of overwriting the live value. Removing a key from the build or its SOPS file now deletes that key from the cluster, and `kix status` reports Secret keys changed on the cluster.
