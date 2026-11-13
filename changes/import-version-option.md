+++
kind = "fixed"
+++
The `version` option of an instance now works when the instance's package is a `kix.mkImport`. Kix checks it in the `meta.compatibleWith` constraints of the packages that depend on the import, in place of the import's `out.version`. Before, Kix ignored the option for an import.
