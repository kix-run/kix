# 2026-09-20 · `kix/packages/{vaultwarden,immich,immich-machine-learning}` · Three application packages hold `meta.unsafe = [ "run-as-root" ]` because their upstream images run as root, not because the app needs it.

Turning the scorecard on at error found them: `security.nonRoot` fires on
each, and the grant is what lets the build pass. All three write a data
volume, so running them as another user means `fsGroup` on the pod and a
provisioner that honours it, which local-path does not. That is a change
to try on a cluster, and nobody has. Until then the grant says "root" where
the honest word is "untested". grafana's `init-chown-data` and velero's
`node-agent` hold the same grant for a real reason.
