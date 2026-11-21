+++
kind = "added"
+++
Kix now blocks `kix deploy` and `kix rollback` when you run a withdrawn version of Kix, and names the version to use instead. Other project commands and `--dry-run` print a warning and continue. The install script, `kix self install <minor>`, `kix self upgrade`, and `kix upgrade` never select a withdrawn release automatically, though an exact version still installs with a warning so projects pinned to it can still run `kix upgrade`. To deploy or roll back with a withdrawn version anyway, set `KIX_ALLOW_WITHDRAWN` to that version. Kix then adds the `kix.run/withdrawn-kix` annotation to the `Activation` record. Kix refreshes its saved release index at most once a day during `kix deploy` and `kix rollback`, and uses the last saved copy when kix.run is unreachable.
