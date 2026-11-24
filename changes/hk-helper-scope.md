+++
kind = "fixed"
+++
Errors and warnings from built-in packages, contract helpers, and failed dependency checks now name the instance and its package in their `instance` and `package` fields, in error output and in `kix check -o json`, instead of in the message text. For an experimental package, `package` is now `experimental/<name>` instead of `<name>`. Warnings and failed assertions now also carry `package`.
