# 2026-09-27 · `kix/packages/ingress-nginx` · The ingress-nginx controller runs with a writable root filesystem.

The chart (4.15.1) sets `controller.image.readOnlyRootFilesystem: false`,
and the package copies it. The controller rewrites `/etc/nginx/nginx.conf`
and writes under `/tmp` and nginx's own directories at runtime, and upstream
documents no set of emptyDir mounts that makes a read-only root work.
`security.readOnlyRootfs` warns for ingress-nginx.
