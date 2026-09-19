# 2026-09-19 · `kix/lib/rules/security.nix`, `kix/packages/cilium` · The full rule set cannot build a cluster that installs its own CNI.

`security.noHostNetwork` and `security.noPrivileged` are errors, and
cilium's agent, envoy and operator pods run on the host network with a
privileged BPF mount, because that is what a CNI is. Every ludo kind
variant installs cilium through kix, so none of them can turn on
`kix.rules` in full. `clusters/test-harbor.nix` downgrades both rules
for `kube-system` to get past it.
