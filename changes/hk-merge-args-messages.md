+++
kind = "changed"
library = ["kix.mergeArgs"]
+++
Errors when `extraArgs` sets a package-owned flag now include a `Fix:` line. The fix tells you to remove the flag or names the package option or dependency to set instead, and notes that `partsOverlays` on the instance can still override the built resource after the package's checks run. Built-in packages reject the same flags as before, except for the flag spellings listed in `[K4740]` and `[K8006]`.
