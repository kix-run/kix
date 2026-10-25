# 2026-10-17 · `kix/lib/vocab/compose.nix` · `kix.withMounts` mounts into `containers` only, never `initContainers`.

A package whose init container needs the same volumes as its main container (plausible's `migrate`, vaultwarden's `init-chown-data`) copies `{ name; mountPath; }` from each mount record into the init container's `volumeMounts` by hand. Nothing checks that the copy stays in step with the main container, and `subPath` or `readOnly` on a mount is dropped unless the copy spells it out. `_injectMounts` selects targets from `spec.template.spec.containers` alone.
