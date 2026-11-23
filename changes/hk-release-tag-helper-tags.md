+++
kind = "fixed"
packages = ["experimental/cert-manager", "experimental/cnpg-barman-cloud", "experimental/envoy-gateway-controller", "experimental/external-dns", "experimental/external-secrets", "experimental/infisical-operator", "experimental/mayastor", "experimental/reloader", "experimental/snapshot-controller", "experimental/tailscale", "experimental/volsync", "experimental/zfs-localpv"]
+++
These packages now refuse an image tag that adds or drops the leading `v` of the upstream tags, such as `1.21.3` for cert-manager, whose images are tagged `v1.21.3`. Before, the build accepted the tag, and the pods failed to pull an image that upstream does not publish. The error for an image tag outside the vendored release now has the same wording in every package that checks it, and mayastor names the image option that holds the tag.
