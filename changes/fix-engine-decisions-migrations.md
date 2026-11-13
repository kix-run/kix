+++
kind = "fixed"
+++
`kix deploy` now stops for a stateful replacement only when both objects hold data: a PersistentVolumeClaim, a PersistentVolume, a StatefulSet with volume claim templates, or a custom resource whose kind declares `holdsData = true`. Before, renaming any object in a package with `lifecycle = "stateful"`, such as a Job, a ConfigMap, or a NetworkPolicy, stopped the deploy until you passed `--accept-migrations`, and that flag also let through any real data migration in the same deploy. A renamed Secret no longer stops the deploy either, because the new Secret gets its values from the package, from its SOPS file, or, for a service account token, from Kubernetes.
