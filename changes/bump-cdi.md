+++
kind = "silent"
packages = ["experimental/cdi"]
+++
`cdi` installs CDI v1.66.1 instead of v1.62.0. Existing DataVolumes and their claims keep working, and the first deploy replaces the CDI pods once. New DataVolumes that use the `storage` form get claims sized for 6% filesystem overhead instead of 5.5%, so the same definition makes a larger claim than before. cdi-operator and cdi-deployment now serve metrics over TLS on port 8443 and require a bearer token. The ServiceMonitor that cdi-operator creates already does this, but any other scrape configuration must add a token. The recording rules `kubevirt_cdi_operator_up` and `kubevirt_cdi_{clone,import,upload}_pods_high_restart` are deprecated in favour of names with a `cluster:` prefix. cdi-operator v1.66.1 cannot be moved back to an older version: an older Kix leaves CDI as v1.66.1 wrote it, and the only way back is to uninstall CDI and install the older release.
