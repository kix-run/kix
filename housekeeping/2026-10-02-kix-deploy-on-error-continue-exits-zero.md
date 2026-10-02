# 2026-10-02 · `cli/kix-cli/src/commands/deploy.rs` · `kix deploy --on-error continue` exits 0 when resources failed.

`run_deploy` returns `Ok` with `failed > 0` under `--on-error continue`, and the command prints the summary and returns `Ok(())`. The W6 kind run K3 saw "Deploy complete: ... 2 failed, 3 cancelled" with exit status 0; the same deploy with the default `--on-error stop` exited 1. Scripts and CI that pass `--on-error continue` cannot tell a failed deploy from a good one by its status. `demo/deploy-ludo-kind-tls.sh` and `demo/deploy-ludo-kind.sh` run `kix deploy ... --on-error continue || warn ...`, so their warning never fires.

- Hit again 2026-10-02 in W6 kind run K13 (`clusters/test-tailscale/`): "1 failed, 6 cancelled" with exit status 0.
