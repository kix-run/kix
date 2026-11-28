# 2026-11-19 · `kix.run/package` annotation · The annotation named `package` holds the instance name.

Every object Kix manages carries `kix.run/package`, and its value is the name of the instance, such as `immich-db`. The package that instance runs is `experimental/stackgres-database`, which the PackageInstance record now holds in `spec.package`. A reader who sees both expects them to agree. The key is defined in `kix/lib/core/annotations.nix` and read in `cli/kix-core/src/manifest/keys.rs`.
- Hit again 2026-11-28: since doc 182, only built manifests carry the annotation. Kix no longer sends it, so live objects no longer have it.
