# 2026-09-19 · `kix/packages/stackgres-operator` · The operator rewrites the ValidatingWebhookConfiguration kix applies, so the second deploy hits a field-ownership conflict.

On the harbor smoke cluster the first `kix deploy` created
`ValidatingWebhookConfiguration/stackgres-operator`; the operator
(field manager `fabric8-kubernetes-client`) then took over
`.webhooks[sgcluster.validating-webhook.stackgres.io].rules`. The next
deploy fails on that object with "another field manager owns one or
more fields kix is trying to set" and cancels the operator's
PackageInstance and the Activation. `--force-conflicts` gets past it
once, and the operator takes the field straight back.
