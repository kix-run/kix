# 2026-11-01 · `kix deploy` · A deploy reports success while the Deployment's new pod is still failing.

On ludo, a template change to `nas/filebrowser` deployed with "Deploy complete: 0 failed" (exit 0), yet the new ReplicaSet's pod sat in `Init:Error`: its init container timed out on a file the old pod still locked. The old pod stayed Ready, so the Deployment still looked available. The readiness wait should check that the rollout reached the new template (`status.updatedReplicas`, `observedGeneration`), as `kubectl rollout status` does.
