+++
kind = "fixed"
packages = ["experimental/kubevirt"]
+++
A deploy that changes the KubeVirt version now waits until KubeVirt reports the new version as installed. Before, the deploy finished while the old virt-api, virt-controller, and virt-handler still ran, because KubeVirt keeps its phase at Deployed during an upgrade.
