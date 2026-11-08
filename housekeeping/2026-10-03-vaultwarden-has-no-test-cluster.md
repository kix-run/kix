# 2026-10-03 · `kix/packages/vaultwarden` · Vaultwarden renders in no kixpkgs cluster, so a change to it has no cheap rendered-output check.

`clusters/` has no test cluster that instantiates vaultwarden.
`clusters/homelab/services.nix` declares it behind `homelab.features.vaultwarden`,
which is off in `homelab-kind`, and only the homelab scenarios in kix-examples
turn it on.
`every-package-evaluates` evaluates its defaults but renders no database
dependency.
