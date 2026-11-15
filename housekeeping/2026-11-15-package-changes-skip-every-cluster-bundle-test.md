# 2026-11-15 · `.github/workflows/bundle-checks.yml` · A pull request that changes a package does not run the test that bundles every cluster.

`every_test_cluster_bundles` runs only in the Bundle checks workflow, whose path filter leaves out `kix/**`. A change to a package or to the library that breaks a cluster outside the fixed set in `scripts/change-kind.py` is found by the weekly run, after the merge. Adding `kix/**` to the filter also runs the fuzz targets on every package change, which costs several minutes of an 8-core runner.

Decision required from the maintainers: whether to run the bundle test, without the fuzzing, on pull requests that change `kix/`.
