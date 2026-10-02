# 2026-09-27 · `kix/packages/{vaultwarden,immich}` · After the switch to non-root, a volume that a root-run release wrote is unwritable on hostPath and local-path storage.

vaultwarden now runs as uid 1001 and immich as uid 1000. On most block CSI volumes `fsGroup` regroups the files on first start.
The kubelet does not apply `fsGroup` to hostPath or local-path volumes, and
ludo uses k3s local-path, so the existing root-owned directories stay as they
are and the app fails to write. Each package has an `initChownData` option
for the first deploy after the upgrade. Using it also needs a `security.nonRoot`
severity override, because the chown container runs as root. Nobody has run
this migration on a real volume yet.
