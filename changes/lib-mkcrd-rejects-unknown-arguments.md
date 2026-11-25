+++
kind = "error"
library = ["scope.mkCRD", "scope.mkCRDRef"]
id = "K9267"
+++
Rename or remove any unknown argument passed to `scope.mkCRD` or `scope.mkCRDRef`. Both functions now reject unknown arguments with `[K9267]`, listing the unknown arguments, the custom resource kind, and the accepted arguments. Previously, `scope.mkCRD` ignored unknown arguments, so a misspelled argument such as `controler` had no effect.
