# 2026-11-12 · `kix/packages/stable/echo-server` · Changing `message` updates the ConfigMap but never the running nginx.

The Deployment carries no hash of the ConfigMap, so the pods do not restart, and nginx does not reload its config. `kix plan` says "tracking annotation only; no spec change or restart" for the Deployment, and the deploy succeeds. On kind the pods still answered "Hello from Kix!" minutes later. This is the first tutorial (`02-hello-world`), whose header promises "edit cluster.nix -> ... see the change".
