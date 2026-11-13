+++
kind = "fixed"
cli = ["kix check"]
+++
`kix check` now shows the Kix library's warnings when the build succeeds. Before, Kix showed them only when the build failed, so you did not see a warning such as a `meta.compatibleWith` check that Kix skipped because a dependency reports no version. Text output lists them under the table. In `-o json` and `-o yaml`, the `eval` row lists each one in `findings` with `severity` and `message`. In `-o sarif`, each one is a result of the rule `kix/library-warning`. Scorecard warnings still appear only as scorecard findings.
