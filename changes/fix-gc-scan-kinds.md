+++
kind = "changed"
cli = ["kix gc --full-scan"]
+++
Pass `--include copies,unstamped` to `kix gc --full-scan` if you want to delete unowned Kix-labeled objects that another controller or tool created without `kix.run/identity-hash`, such as Events an operator posts with a custom resource's labels. By default, `kix gc --full-scan` now lists these objects under "Copied labels" and keeps them; previously, it listed them under "Objects with no matching deployment record" or "No Kix build annotation".

Commands that scan live cluster resources (`kix gc --full-scan`, `kix plan`, `kix plan --read-only`, `kix deploy`, `kix status`, `kix snapshot`, and the Kix operator) now include each Kubernetes object once even when the cluster serves its kind under multiple API groups, such as `Event` under `v1` and `events.k8s.io/v1`. Previously, `kix gc --full-scan` listed those objects twice. When a Kubernetes cluster hosts multiple Kix clusters, the summary line for skipped objects from other Kix clusters now counts and names each other cluster once instead of repeating clusters that share objects.
