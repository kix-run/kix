+++
kind = "silent"
packages = ["experimental/clickhouse", "experimental/clickhouse-cluster", "experimental/clickhouse-keeper", "experimental/clickhouse-database"]
library = ["kix.contracts.experimental.clickhouse"]
+++
The ClickHouse packages now publish the full server version in `out.version`, such as `26.3.33.24`. Before, they published only `26.3`. If your package tests `out.version` for equality with a short version, change it to compare with `lib.versionOlder`, or shorten the value with `lib.versions.majorMinor`. An import that publishes a short version such as `26.3` still works. `clickhouse` and `clickhouse-cluster` now stop the build when `image.tag` does not start with a version, and the error names the setting to change. `clickhouse-database` no longer has the placeholder version `0.1.0`: `kix list` shows no version for it, and its record shows the version of the server it lives on.
