+++
kind = "silent"
packages = ["cnpg-cluster"]
+++
`cnpg-cluster` now publishes the PostgreSQL version with its minor part in `out.version`, such as `18.6`. Before, it published only the major version, `18`. `kix plan` and the PackageInstance record show the longer version. A `meta.compatibleWith` bound such as `maxVersion = "18"` still accepts it. If your package tests `out.version` for equality with a major version, change it to compare with `lib.versionOlder`, or shorten the value with `lib.versions.major`.
