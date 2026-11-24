# 2026-11-24 · `kix/lib/vocab/compose.nix` · `parser = "gnu"` does not read two forms that kingpin accepts.

kingpin reads `--no-<flag>` as a boolean flag set to false, and expands `@<file>` into the words in that file (`parser.go` at v2.4.0). node-exporter and external-dns use kingpin and declare `parser = "gnu"`, so `kix.mergeArgs` passes both forms. Today no owned flag in either package is a boolean the package turns on, and `@<file>` needs a file inside the container, so nothing is exposed. A package that owns a kingpin boolean flag would need to list `--no-<flag>` in `names` by hand.
