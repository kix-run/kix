# 2026-10-02 · `kix/lib/eval/hooks.nix` · A `kix.mkImport` that claims a role is never checked against that role's binding.

`checkRoleBindings` refuses a managed claimant under an `exclusive`
binding, but an import with `roles = [ "cni" ]` (or `storageClasses`)
builds under an `absent` or `exclusive` binding without a word, although
the two say opposite things about the environment. Only a consumer that
checks the pair itself catches it: the `cilium` package refuses a
`platform-cilium` dependency on a binding other than `shadowable`.
