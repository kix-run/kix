+++
kind = "changed"
library = ["kix.mergeArgs"]
+++
No configuration changes are needed. When `extraArgs` sets a flag reserved by a package, the error now states which option or dependency controls the flag (or why the package rejects it) and puts the remedy on a separate `Fix:` line. That `Fix:` line tells you to remove the flag or set the corresponding package option or dependency instead, and notes that `partsOverlays` on the instance can modify the built resource after the package's checks. Built-in packages reject the same flags as before, apart from the alternate dash spellings in `[K4740]` and `[K8006]`, and the underscore spellings in `[K9425]`.
