# 2026-10-02 · `kix/packages/cdi` · Changing a DataVolume's spec halts the deploy, because CDI's webhook refuses spec updates.

A deploy that changes the spec of a DataVolume built with `cdi.out.mkDataVolume`
fails with `admission webhook "datavolume-validate.cdi.kubevirt.io" denied the
request: Cannot update DataVolume Spec` and cancels everything after it. Kix
recreates an object only when its id is in the orphan set, so the user has to
delete the DataVolume (and its data) by hand. Seen in the W6 kind run K7 when
`storage.accessModes` was added to the `scratch` DataVolume of
`clusters/test-virtualization.nix` on a live cluster.
