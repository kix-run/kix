# 2026-11-12 · `cli/kix-cli/src/commands/status.rs` · `kix status` shows a Superseded Activation with STATUS `Active`.

After a deploy, `kubectl get activations` gave `Superseded` for the old record, while `kix status 02-hello-world` listed both records as `True Active`. A reader cannot tell which build is live.
