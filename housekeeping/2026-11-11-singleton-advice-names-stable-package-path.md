# 2026-11-11 · `kix/lib/eval/auto.nix` · The once-per-cluster refusals suggest `packages.<name>` for experimental packages.

`besideConsumerRefusals` and `spreadRefusals` print `instances.<namespace>.<name>.package = packages.<name>;`. For an experimental operator such as `cert-manager` or `stackgres-operator` that path fails with `[K0549]`. The advice should say `packages.experimental.<name>`.
