+++
kind = "fixed"
packages = ["echo-server"]
+++
`echo-server` returns `message` exactly as written. Before, the message went into the nginx configuration unescaped, so a quote broke the configuration and a `$` read an nginx variable. The container also sets the Pod Security "restricted" fields: it cannot gain privileges, drops all Linux capabilities, and uses the runtime's default seccomp profile. The first deploy after the upgrade restarts its pods once.
