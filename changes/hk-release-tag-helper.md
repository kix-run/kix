+++
kind = "added"
library = ["kix.image.checkRelease", "kix.version.ofTag", "meta.version"]
+++
No changes to existing packages are needed. Packages can now set `meta.version` directly to an upstream tag with a leading `v`, such as `"v1.19.6"`. Kix strips any leading `v` when reading `meta.version`, so `PackageInstance` records, `kix list packages`, and `meta.compatibleWith` still receive `"1.19.6"`. `kix.image.checkRelease` builds a package assertion that checks whether an image tag matches the major.minor version of a pinned upstream release (for example, when CRDs or RBAC rules come from that release), ignoring any leading `v` and anything after the minor version. `kix.version.ofTag` extracts the version from a standalone tag string, such as a custom resource's version field, using the same rules as `kix.image.version`.
