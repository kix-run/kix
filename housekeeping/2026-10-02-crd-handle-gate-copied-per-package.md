# 2026-10-02 · `kix/lib/core/resource.nix` · Two packages copy the same wrapper to make custom resources wait for a check Job.

`cert-manager/crds.nix` and `stackgres-operator/default.nix` each define a
`gate` function that overrides `out.cr` and `out.mkCR` on every CRD handle to
add a Job to the custom resource's `requires`. `mkCRDBuilders` already takes
`extraRequires`, but `scope.mkCRDRef` and `scope.mkCRD` do not pass it
through, so the next operator with a late webhook will copy the wrapper again.

`mkCRDRef`'s `installedBy` is a partial route that exists today: it becomes a
`requires` of the CRD marker, and every custom resource requires the marker.
Passing the check Job there creates a cycle while the Job requires a CRD
marker (stackgres's Job requires the SGInstanceProfile marker for its
dry-run), and it stretches what `installedBy` means.
