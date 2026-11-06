# 2026-11-06 · `docs/src/content/docs/tutorials/07-package-anatomy-and-safe-resource-composition.mdx` · The tutorial calls `kix.mount.configMap` with a signature that does not exist.

Line 98 reads `kix.mount.configMap self.configmap "/etc/nginx/conf.d" { }`. The constructor takes a resource and one attribute set, `kix.mount.configMap self.configmap { mountPath = "/etc/nginx/conf.d"; }`, so a reader who copies the tutorial gets a type error. The snippet is inline in the page, not a checked file from `tutorials/`, so no test catches it.
