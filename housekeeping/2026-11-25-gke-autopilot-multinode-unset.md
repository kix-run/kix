# 2026-11-25 · `kix/lib/flavors/gke-autopilot.nix` · The flavor leaves `multiNode` unset, so every Autopilot build warns.

Autopilot adds nodes for pending pods, so required pod spread should always be met. Google's documentation that we read does not say so directly, and no one has tested it. The `gke` flavor now sets `multiNode = true`. Set the same on Autopilot once a live cluster confirms it.
