# 2026-11-18 · `clusters/test-cnpg.nix` · The header does not say which kind node image to use, and kind's default is outside the CloudNativePG range.

kind 0.33 creates nodes from `kindest/node:v1.37.0` by default. The cnpg-operator package sets `meta.k8s.maxVersion = "1.36"`, so a cluster created as the header describes runs a Kubernetes version the package does not support. I created the cluster with `--image kindest/node:v1.36.4` and did not check what Kix does on 1.37. The header could name the image, or the test clusters could share one kind config that pins it.
