+++
kind = "fixed"
+++
Errors, failed assertions, and warnings from built-in packages, contract helpers, and dependency checks now report the instance and package in the diagnostic header (and in the `instance` and `package` fields of `kix check -o json`) instead of repeating those names inside `message`. Diagnostics from experimental packages now report `experimental/<name>` as the package name instead of `<name>`.
