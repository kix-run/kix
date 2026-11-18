+++
kind = "changed"
packages = ["experimental/snapshot-controller"]
+++
`snapshot-controller` runs external-snapshotter v8.7.0 instead of v8.6.0. The VolumeSnapshot CRDs do not change, and the controller picks up the snapshots the old one left. Since v8.7.0 the group snapshot feature gate is on by default. The package now passes `--feature-gates=CSIVolumeGroupSnapshot=false`, so group snapshots stay off as before and the controller does not wait for their CRDs at every start. The first deploy after you upgrade replaces the controller pod once. To go back, deploy the previous Kix release.
