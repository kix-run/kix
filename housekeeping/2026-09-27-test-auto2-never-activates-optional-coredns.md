# 2026-09-27 · `clusters/test-auto2.nix` · The optional-activation test case has no instance that activates it.

The file defines `needsCorednsPackage`, which depends on `coredns`, and
the comment on the optional `infra/coredns` instance says it "will be
activated by needs-coredns". No instance uses `needsCorednsPackage`, so
cluster-auto2 never runs exercise 2 in its header ("Optional
instance activation"). `clusters/test-auto.nix` had the instance; it was
left out when test-auto2 was created in f2dd289. deadnix reports
`needsCorednsPackage` as unused until the instance is added or the
package is removed.
