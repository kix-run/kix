# 2026-09-27 · `kix/packages/tailscale` · The Tailscale operator writes its tsnet state under /root/.config, so it cannot run with a read-only root filesystem as packaged.

The operator logs `tsnet starting with hostname "tailscale-operator",
varRoot "/root/.config/tsnet-operator"` at startup: tsnet takes its
directory from `os.UserConfigDir()`. The image sets no user, so it runs
as root, and the chart (1.82.0) sets no security context. A read-only
root needs an emptyDir at that path, which upstream does not document.
`security.readOnlyRootfs` warns for tailscale.
