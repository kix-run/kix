+++
kind = "security"
packages = ["experimental/kubevirt"]
cve = ["CVE-2026-13318"]
+++
`kubevirt` now installs KubeVirt v1.10.0, which fixes CVE-2026-13318. Before this fix, a malicious QEMU guest agent could redirect `virtctl port-forward` and `virtctl ssh` traffic to any network endpoint, because virt-api dialed the address the guest agent reported. virt-api now dials only the virt-launcher pod's IP. v1.10.0 also compares export server tokens in constant time, and builds with Go 1.26.10 instead of 1.26.4, which brings the Go security fixes released in between.
