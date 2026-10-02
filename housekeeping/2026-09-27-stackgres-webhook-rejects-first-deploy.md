# 2026-09-27 · `kix/packages/stackgres-operator` · On a fresh kind cluster the first deploy can fail one StackGres resource with an x509 error from the operator's admission webhook.

Lane g2 deployed five SGClusters in one `kix deploy`. Four went through;
`SGInstanceProfile/metabase-pg-profile` failed with "failed calling webhook
sginstanceprofile.mutating-webhook.stackgres.io ... x509: certificate signed
by unknown authority", and the deploy cancelled that cluster, its database
and the Activation. The operator pod had restarted twice by then, which
suggests the webhook's CA bundle and serving certificate were briefly out
of step. Re-applying the same manifests a minute later succeeded. Deploy
treats the webhook as ready before it serves the certificate it advertises.

- 2026-10-02: the package now renders both webhook configurations as metadata only, and the operator Deployment requires them, so the operator always takes its update path and writes every entry with its caBundle. Delete this entry once repeated fresh kind deploys and operator restarts show no x509 rejection; that run has not happened yet.
- Hit again 2026-10-02 in the W6 fresh ludo-kind run (K2), the other way round. The SGCluster went through the API server at 06:17:51, one second before the operator wrote its webhook entries, so no mutating webhook gave it a status. The operator's startup then updates every SGCluster to apply defaults, and the validating webhook threw a NullPointerException on the missing status (`StatusUpdateValidator`, StackGres 1.19.2) on every retry. The operator never created the cluster's pods and the deploy failed at its 300 s ceiling. Deleting the SGCluster and deploying again worked. The CRD references wait only for the definitions, which the operator installs before it writes the webhook entries. No x509 rejection was seen in that run, across two operator restarts.
- Hit again 2026-10-02 in the W6 fresh ludo-kind-tls run (K3): the same NullPointerException path, SGCluster `data/postgres` got no status, and the first deploy failed at the 300 s ceiling. Deleting the SGCluster and deploying again worked.

Decision required from the orchestrator or Adam: gate the CRD handles on a check Job that waits for both configurations to hold their entries (the cert-manager pattern, HANDBOOK §22, which needs a pinned kubectl image), or let the operator create the two configurations (a `create` grant on admission webhook configurations) and gate the handles on a declared readiness of them.
- Hit again 2026-10-02 in the W6 fresh kind runs K8 (`./clusters#cluster-harbor`, plain and Sentinel), K9 (`./clusters#cluster-n8n`), and K14 (`./clusters#cluster-metabase`), on every fresh cluster: the SGCluster got no status, the operator logged the `StatusUpdateValidator` NullPointerException 105 to 198 times, and each first deploy failed at the 300 s ceiling. Deleting the SGCluster and deploying again worked every time.
