# 2026-11-24 · `kix/packages/experimental/{external-dns,reloader}` · Two packages read flag values from `extraArgs` with their own matchers.

`kix.guardArgs` decides which argument sets which flag, but only to refuse or replace it. external-dns (`flagValues`) and reloader (`valuesOf`) also need the value a flag was given, so each keeps its own matcher with its own rules for `--flag value` and `--flag=value`. Neither follows a package's `parser`, so a Go-style or mixed-case spelling would slip past them if those programs read one.
