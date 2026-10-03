# 2026-10-03 · `ludo/variants/` · Most ludo-kind variants cannot be deployed to kind without the ludo SOPS key.

`ludo/cluster-kind.nix` replaces the SOPS-backed `grafana-admin` and `valkey-password` Secrets with plain `stringData` for kind, but the variants (for example `cluster-kind-upgrade-small.nix`) import `../base.nix` without that override. On a machine without `sops` or the age key, `kix deploy` and `kix plan` of any such variant stop on `Secret/grafana-admin@monitoring-system` ("SOPS decryption failed"), so the variants do not exercise the change they were written for.
