# 2026-11-13 · `kix-operator/src/controller.rs` tests · The "nothing is superseded" assertion in `a_queued_build_bound_elsewhere_fails_before_anything_is_superseded` cannot fail.

The test's Active record `a-old` has no `app.kubernetes.io/managed-by: kix` label. `Records` lists by that label, so the reconcile never sees `a-old`, and no request names it whatever the code does. The record needs the label for the assertion to test anything.
