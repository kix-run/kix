# 2026-10-01 · `kix/lib/core/activation.nix` · Every package that rightly omits `meta.version` prints a warning and stamps `<undefined>`.

A package that deploys no upstream software, such as `persistent-volume-claim`
and `storage-classes`, has no version to report and omits `meta.version`.
`activation.nix:28-31` then traces
`warning: package <instance> has no version set` on every build and writes
`spec.version = "<undefined>"` on the PackageInstance. Every cluster with a
claim, `every-package-evaluates`, and ludo-kind print it. The CLI filters
`<undefined>` (`cli/kix/src/eval/store_graph.rs:264,483`), so nothing breaks,
but the warning trains readers to ignore warnings. `priority-class` and
`cluster-issuer` will add more.
