# Multi-Component Packages

Complex applications like Harbor have multiple sub-services (core, portal, registry, jobservice, exporter). These are all defined in **one package** — not split into separate packages — because they share config, secrets, and internal URLs.

Reference implementation: `packages/harbor/`.

## Key patterns

1. **Shared let bindings** — define common values (selector labels, security contexts, probe bases, internal URLs) once in the `let` block:
   ```nix
   let
     selectorLabels = { app = "harbor"; release = name; };
     harborPodDefaults = { securityContext = { runAsUser = 10000; ... }; ... };
     probeBase = { httpGet = { scheme = "HTTP"; port = 8080; }; ... };
     coreProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v2.0/ping"; };
   ```

2. **Per-component selectors** — add a `component` label to distinguish pods:
   ```nix
   selector.matchLabels = selectorLabels // { component = "core"; };
   ```

3. **Cross-resource references via enriched `out` API** — secrets use `out.envFrom`/`out.keyRef`, configmaps use `out.name`:
   ```nix
   envFrom = [
     { configMapRef.name = self.coreConfigMap.out.name; }
     self.coreSecret.out.envFrom
   ];
   env = [
     (self.coreSecret.out.keyRef "secret" // { name = "CORE_SECRET"; })
   ];
   ```

4. **Inline PVCs** — when storage is owned by the package (not the cluster operator), define PVCs as resources within the package rather than using DI:
   ```nix
   registryPVC = scope.mkResource {
     apiVersion = "v1"; kind = "PersistentVolumeClaim";
     name = "${name}-registry";
     spec = {
       accessModes = [ "ReadWriteOnce" ];
       resources.requests.storage = config.persistence.registry.size;
     } // lib.optionalAttrs (config.persistence.registry.storageClass != null) {
       storageClassName = config.persistence.registry.storageClass;
     };
   };
   ```
   Use DI PVCs (via `storage` arg) when the cluster operator should own storage lifecycle. Use inline PVCs when the package owns them.

5. **Manual volumes for multi-container pods** — when two containers share volumes (harbor's registry + registryctl), wire volumes manually instead of using `kix.withMounts` (which only works for single-container pods unless you use `kix.withMountsOn`).

6. **`root` with explicit `requires`** — in multi-component packages, many resources aren't reachable via transitive `self.*` references from the entry point. List them in `root.requires`:
   ```nix
   root = {
     resource = if config.ingress.enabled then self.ingress else self.coreService;
     requires = [
       self.coreDeployment self.coreService
       self.portalDeployment self.portalService
       self.registryDeployment self.registryService
       # ... all resources that must exist
     ];
   };
   ```

7. **`root` with `postHooks`** — for Jobs that must run AFTER the package is fully deployed (e.g., webhook cert patching, database migration). Post-hook resources must depend on forward-closure resources (typically root or its descendants) so wave ordering places them after the main package. The PackageInstance CR depends on them, so the package isn't "done" until post-hooks complete. Jobs use existing readiness (`status.succeeded >= 1`).
   ```nix
   root = {
     resource = self.service;
     postHooks = [
       self.migrationJob    # runs after service is ready
       self.webhookPatchJob # runs after operator is deployed
     ];
   };
   ```
   A warning is emitted if a post-hook doesn't reference any forward-closure resource (meaning it won't be ordered after root).
