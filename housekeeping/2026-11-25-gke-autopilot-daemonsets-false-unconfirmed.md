# 2026-11-25 · `kix/lib/flavors/gke-autopilot.nix` · The flavor sets `daemonSets = false`, and Google's documentation does not support it.

Every package with a DaemonSet fails evaluation on `gke-autopilot`. Google's Autopilot security page lists what Autopilot refuses (privileged pods, `hostNetwork`, writable `hostPath`), and DaemonSets are not on it. A first live test on GKE Standard did not cover Autopilot. Someone needs to deploy a plain DaemonSet to a real Autopilot cluster and set the capability from the result.
