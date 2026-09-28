# 2026-09-27 · `kix/packages/filebrowser` · Filebrowser loses its users and settings every time the pod restarts.

The image keeps its database at `/database/filebrowser.db` and its
settings at `/config/settings.json`. The package mounts only the `storage`
PVC, at `/srv`, so both live on an emptyDir and are recreated on every
pod start. Each start runs "quick setup" again and logs a new random
`admin` password. Persisting them needs a second volume or a subPath on
the `storage` PVC outside the served `/srv` tree.
