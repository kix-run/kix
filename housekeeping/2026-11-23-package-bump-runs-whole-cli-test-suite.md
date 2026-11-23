# 2026-11-23 · `.github/workflows/cli-tests.yml` · A change to one package runs the whole CLI test suite.

The workflow triggers on `kix/**`, so a version bump of `n8n` or `openbao`
spends 9 to 13 minutes on an 8-core runner. The trigger cannot simply leave
out `kix/packages/**`. The tests build the `example` and `minimal` clusters
(`snapshot_test.rs`, `commands_test.rs`, `deploy_test.rs`, `diff_test.rs`),
and those use `coredns`, `cert-manager`, `immich`, `valkey`, and the
StackGres packages. A bump of one of those does change a snapshot.

Three options:

1. Leave it. The trigger is correct, and the cost is runner minutes.
2. List the packages those clusters use in the workflow's `paths`. The list
   goes stale when a cluster gains a package, and a package may import a
   file from another package's folder, so a folder list can miss a change.
3. Start the job by comparing what `example` and `minimal` build at the
   base and at the head. Skip the tests when both match and nothing under
   `cli/` changed. This is exact, and costs two evaluations on every run.

Option 3 is the one worth trying. Change kind already builds clusters at
both commits, so the two could share that step.
