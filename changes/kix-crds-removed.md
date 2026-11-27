+++
kind = "error"
library = ["kix.kixCRDs"]
id = "K5132"
+++
Remove any references to `kix.kixCRDs` from cluster definitions and packages. Evaluating `kix.kixCRDs` now fails with `[K5132]`. The Kix library removed `kixCRDs` because Kix now installs its CustomResourceDefinitions directly when a deploy starts instead of emitting them in cluster builds.
