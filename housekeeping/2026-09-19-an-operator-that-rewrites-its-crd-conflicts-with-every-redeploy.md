# 2026-09-19 · `cli` apply · When an operator rewrites a CRD that kix ships, every deploy after the first fails with a field-ownership conflict, and the only way out is `--force-conflicts` for the whole deploy.

cdi-operator v1.62.0 drops the deprecated v1alpha1 version from
`cdis.cdi.kubevirt.io` as soon as it runs, so a second `kix deploy` of
`clusters/test-operators.nix` stopped with "conflict with cdi-operator
on .spec.versions" and cancelled 61 resources behind it. The package now
ships the CRD without v1alpha1 so both sides agree, but that is a fix
per operator. A resource cannot say "take these fields back" or "let the
operator keep this field" on its own; `--force-conflicts` is all or
nothing, and it hides real conflicts everywhere else.
