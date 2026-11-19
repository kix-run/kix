+++
kind = "added"
+++
`kix list packages -o json` and `-o yaml` now include a `package` field on each entry. For built-in Kix packages, `package` is the package ID used in release notes, such as `harbor` or `experimental/coredns`. For custom packages and imports, `package` is `null`.
