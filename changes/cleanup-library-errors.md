+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
+++
Errors that the Kix library writes for you now show without a stack trace. Each one gives its change id, the instance, the message, and what to change, and `kix check -o json` lists them under the eval row's `findings`. Other evaluation errors show the nearest stack frames only when they point at your project's own files. Packages and cluster definitions can raise these errors with `scope.fail` and `kix.fail`, and an assertion can now give `fix`, `id`, and `option`. Packages should use `scope.fail` instead of `throw` for errors a person must fix.
