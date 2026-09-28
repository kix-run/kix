# 2026-09-27 · `kix/packages/stackgres-operator` · On a fresh kind cluster the first deploy can fail one StackGres resource with an x509 error from the operator's admission webhook.

Lane g2 deployed five SGClusters in one `kix deploy`. Four went through;
`SGInstanceProfile/metabase-pg-profile` failed with "failed calling webhook
sginstanceprofile.mutating-webhook.stackgres.io ... x509: certificate signed
by unknown authority", and the deploy cancelled that cluster, its database
and the Activation. The operator pod had restarted twice by then, which
suggests the webhook's CA bundle and serving certificate were briefly out
of step. Re-applying the same manifests a minute later succeeded. Deploy
treats the webhook as ready before it serves the certificate it advertises.
