# 2026-10-04 · `kix/packages/external-secrets` · No second deploy has shown that `kix deploy` leaves the webhook Secret's data in place.

`clusters/test-external-secrets.nix` deployed on kind on 2026-10-04: the webhook started once the cert-controller filled `<instance>-webhook-tls`, and the webhook check Job passed. The cert-controller writes that Secret's `data`, so a later `kix deploy` must not empty it. Deploy the cluster twice on kind and check the webhook still admits an ExternalSecret.
