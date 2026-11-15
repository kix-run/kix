+++
kind = "fixed"
packages = ["echo-server"]
+++
`echo-server` now returns `message` exactly as written, including quotes and `$` characters. Before, it wrote `message` directly into the nginx configuration, so a quote broke the configuration and `$` expanded as an nginx variable. The package also now meets the `restricted` Pod Security Standard, so it builds and runs in restricted namespaces. Its container disables privilege escalation, drops all Linux capabilities, and uses the container runtime's default seccomp profile. The first deploy after upgrading restarts every `echo-server` pod once.
