# 2026-10-03 · `cli/kix-cli/src/commands/deploy.rs` · The plan gate stops a deploy that would fix the admission path it is refused by.

The dry run checks every object against the cluster as it is now. When a
webhook with `failurePolicy: Fail` has a broken backend that this deploy
fixes, a policy this deploy relaxes, or a RoleBinding names a ClusterRole the
same deploy creates, every affected write is refused and the deploy stops
under `--on-error stop`. The only way through is `--on-error continue`.
CRD changes are handled (`crd_changed_by_this_deploy`); these are not.
- Hit again 2026-10-17 on a fresh kind cluster (`clusters/test-plausible.nix`): a transient ghcr.io "not found" on the cnpg-operator image halted the first deploy after the CNPG webhook configurations were written and before `cnpg-webhook-service` was, so the next deploy's dry run refused the `Cluster` and `Database` writes until rerun with `--on-error continue`.
