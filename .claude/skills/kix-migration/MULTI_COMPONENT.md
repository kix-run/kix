# Multi-Component Packages

Complex applications like Harbor have multiple sub-services (core, portal, registry, jobservice, exporter). These are all defined in **one package** — not split into separate packages — because they share config, secrets, and internal URLs. The exception is a sub-component that is independently reusable (Harbor's postgres and redis): that is a DI dep (`database`, `valkey`), not a sub-component (BEST-PRACTICES §12.5).

Reference implementation: `packages/harbor/`.

## Key patterns

1. **Shared let bindings** — define common values (security contexts, probe bases, internal URLs) once in the `let` block:
   ```nix
   let
     harborPodDefaults = { securityContext = { runAsUser = 10000; ... }; ... };
     probeBase = { httpGet = { scheme = "HTTP"; port = 8080; }; ... };
     coreProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v2.0/ping"; };
   ```

2. **Per-component selectors and Service labels** — derive both from `scope.selectorLabels`, and give every Service its own `app.kubernetes.io/component` value. `architecture.distinctSameKindLabels` (error) refuses two Services in one instance that carry the same labels, because nothing selecting by labels could tell them apart. Use container port *numbers* as `targetPort` in any Service you write by hand: the netpol layer copies them into consumers' egress rules and cilium drops egress on a named port (`fromWorkload` resolves names for you):
   ```nix
   componentSelector = c: scope.selectorLabels // { "app.kubernetes.io/component" = c; };
   componentLabels = c: { "app.kubernetes.io/component" = c; };

   coreDeployment = { name = "${name}-core"; labels = componentSelector "core";
                      spec.selector.matchLabels = componentSelector "core"; ... } |> scope.mkDeployment;
   portalService = self.portalDeployment
     |> kix.service.fromWorkload { name = "${name}-portal"; labels = componentLabels "portal"; ... }
     |> scope.mkResource;
   ```

3. **Internal URLs carry facts** — components dial each other through `self.<service>.out.fqdn`, never a bare `"${name}-core"` string. The fqdn carries the endpoint fact, which is what gives the consuming pod its netpol egress and orders it after the Service:
   ```nix
   coreUrl = "http://${self.coreService.out.fqdn}:${self.coreService.out.port}";
   ```

4. **Breaking a mutual-dial cycle** — when two components dial each other (Harbor's core and jobservice), one direction has to lose its workload edge or the store paths recurse. Build that one Service with a literal selector, shared with its Deployment so the two cannot drift, and put the Deployment in `root.requires` to restore the ordering edge. The `selectorCoherence` warning this raises is deliberate (BEST-PRACTICES §12.6). Choose the side by boot order, not by convenience: the Service that goes literal is the one whose pod must start *later*. Jobservice fetches its configuration from core's API on boot and panics until core answers, so the jobservice Service is the literal one and its Deployment carries an explicit `requires` on core (verified on a kind cluster: the other way round, jobservice crash-loops and the deploy fails). A component whose own config names its own Service (core's `CORE_URL`) has to be literal as well:
   ```nix
   coreSelector = componentSelector "core";           # core dials itself (CORE_URL)
   jobserviceSelector = componentSelector "jobservice";
   coreService = scope.mkResource { kind = "Service"; ...; spec.selector = coreSelector; ... };
   jobserviceService = scope.mkResource { kind = "Service"; ...; spec.selector = jobserviceSelector; ... };
   jobserviceDeployment = { ...; requires = [ self.coreDeployment ]; spec.selector.matchLabels = jobserviceSelector; ... } |> scope.mkDeployment;
   # root.requires = [ self.coreDeployment self.jobserviceDeployment ... ]
   ```

5. **Cross-resource references via the enriched `out` API** — secrets use `out.mkEnv`/`out.keyRef`, configmaps use `out.name`. Keep every credential in one `scope.mkSecret` with declared `keys` (SOPS `source` in real clusters, `stringData` on dev clusters) so each component's `mkEnv` is validated at build time:
   ```nix
   env = (self.credentials.out.mkEnv { CORE_SECRET = "coreSecret"; JOBSERVICE_SECRET = "jobserviceSecret"; })
     ++ (database.out.credentials.out.mkEnv { POSTGRESQL_PASSWORD = "password"; });
   envFrom = [ { configMapRef.name = self.coreConfigMap.out.name; } ];
   ```
   A password that has to appear inside a URL goes through `$(VAR)` expansion: put the `secretKeyRef` entry first in `env` and the URL after it, so no ConfigMap ever carries the secret. Stamp `template.metadata.annotations."checksum/config" = self.<configMap>.out.identityHash` (and `checksum/secret`) on every pod template, or a ConfigMap change never rolls the pods.
   A component that dials a dependency it was not handed facts for gets no netpol egress: jobservice takes its database settings from core's API, so its env repeats the `database.out.*` facts purely to carry the edge.

6. **Storage is a DI dep** — the registry's blobs come from a `storage` dep (`kix.mount.pvc storage { ... }`); scratch data (job logs) is an `emptyDir`. A package that builds its own PVC needs `meta.unsafe = [ "raw-pvc" ]` and the `unsafeGrants` audit lists it forever.

7. **Multi-container pods** — inject shared volumes once with `kix.withMountsOn "<container>"`, and let the second container mount them by the mount objects' names:
   ```nix
   registryConfigMount = kix.mount.configMap self.registryConfigMap { name = "registry-config"; ... };
   # registryctl container:
   volumeMounts = [ { name = self.registryConfigMount.name; mountPath = "/etc/registryctl/config.yml"; subPath = "ctl-config.yml"; } ];
   # pipeline:
   |> kix.withMountsOn "registry" [ self.registryConfigMount self.registryDataMount ]
   ```

8. **One `kix.monitor` per metrics Service** — a ServiceMonitor selects one Service's labels; several metrics Services mean several entries, each with its own `name`, `monitorPart` and `rulesPart`. Alert rules ride on one of them:
   ```nix
   (kix.monitor { service = "coreService"; port = "http-metrics"; name = "${name}-core";
                  monitorPart = "coreMonitor"; rulesPart = "coreAlerts"; inherit alerts; })
   (kix.monitor { service = "registryService"; port = "http-metrics"; name = "${name}-registry";
                  monitorPart = "registryMonitor"; rulesPart = "registryAlerts"; })
   ```

9. **`root` with explicit `requires`** — list what the entry point cannot reach through `self.*` references. As with a bare `root`, `resource` *aliases* a named part — never construct a resource inside `root` itself, or it renders nothing at all (see "root must alias a named part" in SKILL.md). Optional parts are `null` when disabled, so filter:
   ```nix
   root = {
     resource = if self.ingress != null then self.ingress else self.coreService;
     requires = builtins.filter (r: r != null) [
       self.coreDeployment      # cycle-breaker: the core Service carries no workload edge
       self.exporterService     # nothing dials the exporter
       self.coreMonitor self.coreAlerts self.registryMonitor ...
     ];
   };
   ```
   The orphan warning tells you what you forgot.

10. **`root` with `postHooks`** — for Jobs that must run AFTER the package is fully deployed (e.g., webhook cert patching, database migration). Post-hook resources must depend on forward-closure resources (typically root or its descendants) so wave ordering places them after the main package. The PackageInstance CR depends on them, so the package isn't "done" until post-hooks complete. Jobs use existing readiness (`status.succeeded >= 1`).
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
