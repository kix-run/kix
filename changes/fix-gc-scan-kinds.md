+++
kind = "changed"
cli = ["kix gc --full-scan"]
+++
Pass `--include copies` to `kix gc --full-scan` to delete Kix-labeled objects created by another controller or tool without an owner reference or `kix.run/identity-hash` build annotation. For example, an operator may create Events that copy a custom resource's labels. By default, `kix gc --full-scan` now lists these objects under "Copied labels" and keeps them. Previously, it listed them under "Objects with no matching deployment record" or "No Kix build annotation".

Commands that scan live cluster resources (`kix gc --full-scan`, `kix plan`, `kix plan --read-only`, `kix deploy`, `kix status`, `kix snapshot`, and the Kix operator) now include each Kubernetes object once even when the cluster serves its kind under multiple API groups, such as `Event` under `v1` and `events.k8s.io/v1`. Previously, `kix gc --full-scan` listed those objects twice. When a Kubernetes cluster hosts multiple Kix clusters, the summary line for skipped objects from other Kix clusters now counts and names each other cluster once instead of repeating clusters that share objects.
