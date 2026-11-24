# 2026-11-06 · `cli/kix-bundle/tests/plan_bound.rs` · The plan-bound property test fails on some random cases: a changed `kix.run/package-namespace` annotation on a PackageInstance deploys without the plan file showing it.

`a_changed_bundle_is_refused_or_deploys_what_its_plan_shows` runs without failure persistence, so it fails on roughly one run in three and passes when run again. The failing case set `kix.run/package-namespace` of `PackageInstance/secret-ref-immich-pg-immich-pg@immich` to `v1` (proptest `seed: 2`, a `CopyIdentity` plus a `SetField` change). Either the plan should show that change or the reader should refuse the bundle.

- Hit again 2026-11-23 on main, in the CLI tests run for the merge of pull request 294 (run 45250603714). A different case: an `AddListing` plus a `SetField` change, `seed: 2`, `old: Deployed`. The deploy wrote `PackageInstance.kix.run/firezone-db@firezone` as Added and the plan file did not show it. The next two runs on main passed.
