+++
kind = "silent"
packages = ["experimental/cert-manager"]
+++
`cert-manager` moves from v1.21.2 to v1.21.3. The new images no longer include the emSign ECC Root CA - G3 root certificate. An issuer that reaches a server whose certificate chains to that root, such as some private ACME servers or private CAs, fails the TLS check after the upgrade. Check those issuers before you upgrade. The other changes need no action: the CRDs gain an optional `status.acme.ari.certID` field, and the release fixes an ACME renewal loop and a controller that could copy a private key from a Secret its Certificate does not own.
