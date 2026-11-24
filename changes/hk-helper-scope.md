+++
kind = "fixed"
+++
Errors, failed assertions, and warnings from built-in packages, contract helpers, and dependency checks now set `instance` and `package` in error output and `kix check -o json` instead of repeating those names in `message`. Experimental packages now set `package` to `experimental/<name>` instead of `<name>`.
