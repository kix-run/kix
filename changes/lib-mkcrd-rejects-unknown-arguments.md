+++
kind = "error"
library = ["scope.mkCRD", "scope.mkCRDRef"]
id = "K9267"
+++
`scope.mkCRD` and `scope.mkCRDRef` now refuse an argument they do not take. Before, a misspelt argument such as `controler` was ignored, so the setting did nothing. Kix now stops with `[K9267]`, which names the argument, the kind and the arguments the builder accepts. Correct the spelling, or remove the argument.
