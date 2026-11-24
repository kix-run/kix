+++
kind = "changed"
library = ["kix.mergeArgs"]
+++
When `extraArgs` sets a flag that a package owns, the error now has a `Fix:` line. It says to remove the flag from the option, or names the option or dependency to set instead. It then says that an overlay in the instance's `partsOverlays` can still change the built resource, and that Kix does not check what an overlay changes. The set of flags each built-in package refuses is unchanged, except as the breaking entries for `[K4740]` and `[K8006]` describe.
