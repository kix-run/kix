---
title: "Leaner Packages"
date: 2026-03-24
date_end: 2026-03-26
series: 12
commits:
  - fabe8d1  # feat: new leaner package structure with support for groupings
  - 92e232a  # feat: meta system and default aliases
  - 40f5557  # feat: auto-import packages
  - 797db36  # feat: di driven defaults
  - 4079ef5  # feat: deps in build definition instead of package definition
---

# Leaner Packages

*2026-03-24 to 2026-03-26 -- Post 12*

---

After migrating 26 packages, the boilerplate patterns became obvious. Every package carried the same ceremony: manually registering itself in the flake, declaring its own dependencies, hardcoding defaults that really belonged to the cluster. Five changes over three days stripped it back to what a package actually needs to say.

## Deps moved out of packages

Previously a package declared its dependencies as arguments to its own function. The immich package, for example, pulled in `postgres`, `valkey`, `storage`, and several optional services right in its top-level signature:

```nix
# Before — package function declares deps
{ scope, lib, kix, valkey, postgres, storage, ingressNginx ? null }:
{
  build = { self, config, ... }: { ... };
}
```

This mixed two concerns. The package knows what resources it produces. But which postgres instance it connects to, or whether ingress is available -- that is a wiring decision the cluster should make.

Dependencies moved to the `build` function arguments. The package function now takes only system args. The evaluator introspects the build function, discovers what it needs, and resolves deps from the cluster definition:

```nix
# After — deps discovered from build args
{ scope, lib, kix }:
{
  build = { self, config, postgres, storage, ingressNginx ? null, ... }: { ... };
}
```

Same analogy as a C library: the library does not decide which other libraries get linked. The application (the cluster) does.

## Auto-import

Before this change, every new package required a manual entry in `flake.nix`. Now the evaluator scans the `packages/` directory automatically. Create a folder, add a `default.nix`, and it appears in `packages.*`. The flake wiring is gone.

This also meant breaking the monolithic `lib/eval.nix` (1600+ lines) into focused modules: `auto.nix` for discovery, `instance.nix` for evaluation, `resolve.nix` for dependency resolution, `scope.nix` for context injection.

## Groupings

Large packages like harbor contain multiple logical components: registry, portal, jobservice, trivy. Previously these were either one giant package or awkwardly split into separate packages that had to coordinate.

**Groupings** let a package expose named sub-groups of resources. The package defines them internally. The cluster can selectively include or exclude groups. A harbor install that skips trivy scanning does not need a separate package -- it just omits that group.

## Meta system and default aliases

Packages now declare **metadata**: what namespace they typically live in, what kind of service they provide, what short names make sense. A package can declare `aliases = [ "certManager" ]`, and the cluster can reference it by that short name without ambiguity.

The meta system (`lib/meta.nix`) also enables the evaluator to peek at package metadata without fully evaluating the package. This matters for dependency resolution -- the system needs to know what a package provides before it decides how to wire things together.

## DI-driven defaults

The last piece was **dependency injection for defaults**. Instead of each package hardcoding values like resource limits, storage classes, or backup schedules, the cluster can inject defaults that flow through to every package -- or to every package in a specific namespace.

A cluster-level declaration like "all packages in the apps namespace use the `fast` storage class" applies automatically. Packages still override when they need to. But the common case -- dozens of packages sharing the same infrastructure defaults -- no longer requires touching each package individually.

## The pattern

Each of these five changes removes a reason to edit a package when all you really want is to change how it is wired. The package becomes a pure description: "given this config, here are the Kubernetes resources I produce." Namespace assignment, dependency wiring, default values, even registration in the build system -- all of that lives in the cluster definition now.

The result is packages that are shorter, less coupled, and easier to write. When someone adds a new service, they create a folder, write the resource definitions, and the cluster definition handles everything else.
