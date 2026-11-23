+++
kind = "added"
library = ["kix.image.checkRelease", "kix.version.ofTag", "meta.version"]
+++
Packages can now set `meta.version` directly to an upstream tag with a leading `v`, such as `"v1.19.6"`. Kix strips the leading `v` when reading `meta.version`, so `PackageInstance` records, `kix list packages`, and `meta.compatibleWith` continue to see `"1.19.6"`. For packages whose CRDs or RBAC come from a fixed upstream release, `kix.image.checkRelease` builds an assertion checking that an image tag matches that release's major.minor version and `v` prefix. `kix.version.ofTag` extracts the version number from a standalone tag string, such as a version field on a custom resource, using the same rules as `kix.image.version`.
