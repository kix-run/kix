+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
+++

Packages, contracts, and the Kix library now raise user-facing errors with `scope.fail` or `kix.fail`. Kix shows each error without a stack trace and names the instance, the setting to change, and the fix. `kix check -o json` lists them as findings. A test now fails any package, contract, or module that calls `throw`.
