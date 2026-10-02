# 2026-10-01 · `kix/lib/rules/reliability.nix` · `reliability.hasProbes` warns for containers whose upstream binary serves no health endpoint, and a package cannot record that.

cert-manager v1.21.2's controller serves only `/livez` on 9403 and cainjector serves nothing but `/metrics`, so `kix/packages/cert-manager` gets three `hasProbes` warnings on every build that a package author cannot fix. tailscale and openebs carry their own entries for the same rule. A per-container acknowledgement with a reason would let the scorecard separate upstream facts from omissions.
