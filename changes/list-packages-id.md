+++
kind = "added"
+++
`kix list packages -o json` and `-o yaml` now print a `package` field on every row: the id that release notes use for the package, such as `harbor` or `experimental/coredns`, or `null` for a package that is not one of Kix's own.
