+++
kind = "silent"
packages = ["experimental/spegel"]
+++
`spegel` installs Spegel 0.8.1 instead of 0.7.4. Spegel 0.8 needs containerd 2.2 or later on every node, and its pods exit with an error on an older containerd, which Kix cannot detect. Upgrade containerd before you upgrade Kix. Each node's mirror configuration now names only NodePort 30021, and the registry Service sends that traffic to the node's own Spegel pod first. The pods no longer use hostPort 30020. Spegel 0.8 replaces the metrics `spegel_advertised_images`, `spegel_advertised_image_tags`, and `spegel_advertised_image_digests` with `spegel_advertised_keys`, so update any dashboard or query that reads them. To go back, deploy the previous Kix version. Spegel 0.7 rewrites the mirror configuration on each node when it starts.
