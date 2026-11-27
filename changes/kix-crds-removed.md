+++
kind = "error"
library = ["kix.kixCRDs"]
id = "K5132"
+++
Remove any references to `kix.kixCRDs` from cluster definitions. The Kix library removed `kixCRDs` because Kix now installs its internal CustomResourceDefinitions directly during deploy rather than emitting them in builds; evaluating `kix.kixCRDs` now fails with `[K5132]`.
