# 2026-10-01 · `kix/lib/core/resource.nix` · An instance under `instances._cluster` emits a PackageInstance the apiserver refuses.

PackageInstance is a namespaced kind (`resource.nix:681-684`), so an
instance under the `_cluster` sentinel key renders one with
`metadata.namespace: _cluster`. `_cluster` is not a valid namespace name,
and the CLI uses the same string as its cluster-scoped sentinel
(`cli/kix/src/manifest/types.rs:6`). Packages that create only
cluster-scoped objects, such as `priority-class`, therefore need a real
namespace for their record. See ROADMAP "Cluster-level instances".
