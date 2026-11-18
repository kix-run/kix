# 2026-11-17 · `kix/packages/experimental/filebrowser` · `filebrowser users ls` in the running pod fails with "timeout" because the server holds the database lock.

Found while checking the filebrowser 2.63.23 upgrade on kind. `kubectl exec deploy/filebrowser -- filebrowser users ls` prints "Error: timeout". The server keeps the bolt database open, so a second process cannot open it. The package gives no other way to list users from inside the pod, and the sync-users init container's output shows the same table only on start. Not tested on 2.63.18.
