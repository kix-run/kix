+++
kind = "security"
packages = ["experimental/kubevirt"]
cve = ["CVE-2026-13318"]
+++
`kubevirt` installs KubeVirt v1.10.0 instead of v1.9.1, and virt-template v0.3.0 instead of v0.2.3. It fixes CVE-2026-13318, where a guest agent could redirect `virtctl port-forward` and `virtctl ssh` traffic to any address. virt-api now connects only to the virt-launcher pod. It also fixes a timing side channel in the export server's token check. The first deploy replaces the KubeVirt pods once, and running virtual machines keep their old virt-launcher pods until they restart or migrate. Other changes in v1.10.0: every KubeVirt container runs with a read-only root filesystem, new VirtualMachineExport Services are headless on port 8443, the slirp network binding sidecar image is gone, and `VirtualMachineBackup` status replaces `status.type` with a type per volume and its endpoint fields with `links`. Going back to v1.9.1 does not work.
