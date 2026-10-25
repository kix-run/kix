# 2026-10-17 · `kix/lib/scope/builders.nix`, `cli/kix/src/cluster/ops/sops.rs` · The SOPS `hash` of `mkSecret` is never verified, and it is stamped under the annotation the deploy uses for its own hash.

`scope.mkSecret` writes a caller's `hash` to `kix.run/content-hash`
(`kixKeys.contentHash`). ROADMAP.md line 114 and
`v2_discussions/archive/76_secrets_design.md` say the deploy compares it to
the decrypted SOPS data; `sops.rs` contains no hash code, so a wrong
`passwordHash` is accepted. `cli/kix/src/plan/mod.rs:833` lists
`kix.run/content-hash` among the stamps the deploy writes itself, so the
two meanings share one key. The option descriptions on `cnpg-database`,
`stackgres-database`, and `clickhouse-database` promise the comparison.
