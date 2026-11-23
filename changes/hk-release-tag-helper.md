+++
kind = "added"
library = ["kix.image.checkRelease", "kix.version.ofTag", "meta.version"]
+++
A package can set `meta.version` to an upstream tag with a leading `v`, such as `v1.19.6`. Kix removes the `v` when it reads the version, so the PackageInstance record, `kix list packages`, and `meta.compatibleWith` still see `1.19.6`. The new `kix.image.checkRelease` returns an assertion that an image tag has the major.minor of the release the package vendors its CRDs and RBAC from, and the same leading `v` as that release. `kix.version.ofTag` reads the version from a tag that is not part of an image option.
