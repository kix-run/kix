# 2026-09-30 · `ownership.cede` on the stackgres-operator webhooks · A ceded field still conflicts: kix sends `webhooks[*].rules` and the deploy halts on the operator's field manager.

The package cedes `webhooks[*].rules` on both webhook configurations so the second deploy applies without them. On stage2's second, third and fourth deploys `ValidatingWebhookConfiguration/stackgres-operator` failed with `conflict with "fabric8-kubernetes-client" … .webhooks[name="sgcluster.validating-webhook.stackgres.io"].rules`, and only `--force-conflicts` got past it.
