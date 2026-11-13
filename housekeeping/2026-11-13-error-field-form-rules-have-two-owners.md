# 2026-11-13 · `kix/lib/core/error.nix` · The rules for how an error names its setting live in two places.

`badSetting` in `kix/lib/core/error.nix` refuses an `option` that starts with `config.`, `deps.`, or `meta.` when the error is raised. The test `kix/lib/tests/units/lib-error-fields-form.nix` checks the same prefixes again with a regular expression over the library source. The rule that a `fix` starts with a capital letter exists only in that regular expression. A change to one copy does not reach the other. Decide which one owns each rule.
