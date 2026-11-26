+++
kind = "error"
library = ["kix.kixCRDs"]
id = "K5132"
+++
The library no longer has `kixCRDs`, because builds no longer contain Kix's own CustomResourceDefinitions. A cluster definition that reads `kix.kixCRDs` stops with `[K5132]`. Remove the reference.
