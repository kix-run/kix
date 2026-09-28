# 2026-09-27 · `kix/packages/cloudflared` · Changing the tunnel token does not restart the cloudflared pods.

The container reads `TUNNEL_TOKEN` from the `<name>-token` Secret through
`secretKeyRef`, and the pod template carries no hash of the Secret. On
the lane g1 kind run, `kix deploy` updated the Secret and left the
Deployment unchanged, so running pods kept the old token until they
restarted for another reason. python-app solves the same problem for
its ConfigMap with a `checksum/config` annotation; other packages that
read Secrets or ConfigMaps into env vars are likely affected too.
