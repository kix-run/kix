+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
+++

Every error that Kix's packages, contracts, and library raise for a person now comes from `scope.fail` or `kix.fail`. Kix shows each one without a stack trace and names the instance, and where there is one, the setting to change and the fix. `kix check -o json` lists them as findings. A test now fails any package, contract, or module that uses `throw`.
