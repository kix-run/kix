# 2026-09-19 · `kix/lib/scope/builders.nix` · `mkCRD` gives the CR builders the first version in `spec.versions`, not the storage version.

Vendored CRDs carry more than one version, and upstream does not always
list the storage version first: cdi lists `v1alpha1` before `v1beta1`. The
package filters that version out today, which hides the problem. The
builders should pick `storage = true` and `mkCR` should take a `version`
override (doc 146 §5.5).
