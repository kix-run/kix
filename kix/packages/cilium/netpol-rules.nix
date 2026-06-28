# Cilium network-policy rule builder.
#
# The implementation was moved to the sibling `cilium-external` package
# when it was promoted to top-level (commit 2808d3a, a pure rename), but
# this package's `default.nix` still imports `./netpol-rules.nix`. Both
# packages must expose the identical rule API, so re-export the single
# source of truth from cilium-external rather than keeping a second copy.
import ../cilium-external/netpol-rules.nix
