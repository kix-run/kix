# 2026-10-02 · `cli/kix/tests/fixtures/record.sh` · The fixture for a `/scale` write with no recorded owner is derived in the test, not recorded from a cluster.

`fieldsv1_fixtures.rs` builds the scaled-to-0 and scaled-back Deployments by
editing the recorded `deployment.json` the way the apiserver's ScaleHandler
does (k8s.io/apimachinery v0.36.1). `record.sh` has no step that runs
`kubectl scale --replicas=0` and back, so a change in apiserver behaviour
would not show up in the fixtures. Add that step and record a real object the
next time a kind cluster is up.
