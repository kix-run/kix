+++
kind = "silent"
packages = ["experimental/kubevirt"]
+++
`kubevirt` moves to KubeVirt v1.10.0, which changes the fields that the alpha MigrationStallDetection feature gate sends between virt-handlers. If you turned that gate on in `extraSpec.configuration.developerConfiguration.featureGates`, remove it and deploy before you upgrade Kix, or the KubeVirt upgrade does not finish.
