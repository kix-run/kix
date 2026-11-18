+++
kind = "silent"
packages = ["experimental/arc"]
+++
`arc` runs the GitHub Actions Runner Controller 0.15.1 (was 0.14.2). This is a new minor version, and the controller deletes every runner set whose version label names another minor version. The deploy relabels the runner sets, but when the new controller reaches a runner set before the deploy relabels it, the controller deletes the runner set, and it is missing after the deploy. Run `kix deploy --reconcile` once after the upgrade to re-create any missing runner sets. The listener Role may now patch pods, and the controller has 35 seconds to shut down (was 10). To go back, deploy the previous Kix release, then run `kix deploy --reconcile`.
