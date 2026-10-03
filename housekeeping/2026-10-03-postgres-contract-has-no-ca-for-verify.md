# 2026-10-03 · `kix/lib/vocab/postgres-database.nix` · The Postgres contract publishes no CA, so consumers cannot verify the server certificate.

When a provider publishes `tls = true`, Keycloak and Harbor connect with
`sslmode=require`. That refuses plaintext but accepts any certificate, so a
man-in-the-middle with its own certificate still reads the traffic.
`verify-ca` and `verify-full` need the server's CA. The contract has no field
for it, so no consumer can ask for either mode. StackGres and CloudNativePG
both keep their CA in a Secret that the contract could reference.
