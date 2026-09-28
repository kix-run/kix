# 2026-09-27 · `cli/kix-cli/src/commands/gc.rs` · Soft `kix gc` shows a kept Namespace or CRD as a deletion in its package plan.

Soft mode renders its plan with `plan::diff_garbage` and `plan::print_package_plan`, which mark every resource that left the build with a red `-`. A Namespace or CustomResourceDefinition among them is then listed again under "Kept" and never deleted, so the same object appears as both removed and kept. Hard mode lists only the resources it will delete. The package plan would need to know about `lifecycle::never_pruned`.
