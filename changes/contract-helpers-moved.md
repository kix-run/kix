+++
kind = "error"
library = ["kix.contracts.redis", "kix.contracts.smtp", "kix.contracts.oidc", "kix.contracts.gateway"]
id = "K6218"
+++
For packages that read a contract: the functions a contract gives its readers
moved under `helpers`. For example, `kix.contracts.redis.usesSentinel` is now
`kix.contracts.redis.helpers.usesSentinel`, and the same holds for
`requirePlaintext`, the SMTP `server`, `settings`, and `egressPolicy`, the OIDC
`client` and `endpointKeys`, and the gateway `claims`. `credentialKeys` is now
`fields.credentials.keys` on the same contract, and
`kix.contracts.oidc.clientOptions` is `kix.contracts.oidc.options`. The old
names fail with an error that gives the new one.
