# 2026-10-01 · `kix/packages/cluster-issuer` · The only build-time check of a custom resource's fields against its CRD schema lives inside one package.

`cluster-issuer` walks its ClusterIssuer spec against the `openAPIV3Schema`
of cert-manager's vendored CRD (`certManager.out.clusterIssuerSpecSchema`) and
refuses unknown and missing required fields at evaluation. Every other
`scope.mkCR` call, including Certificates built from the same cert-manager
handles, gets no such check, and a typo reaches the API server. The walk
belongs in `mkCR` or the CRD handle so every vendored CRD gets it; ROADMAP.md
"OpenAPI schema validation at build time" is the open item.
