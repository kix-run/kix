+++
kind = "note"
packages = ["experimental/tempo"]
+++
`tempo` runs Tempo 3.1.1 instead of 3.1.0. Tempo 3.1.1 is built with Go 1.27.3, which fixes the Go security issues listed in its release notes, and it updates its dependencies. Tempo's own code is unchanged, so your settings keep their meaning. The first deploy restarts the Tempo pod once and keeps the traces it holds. Upstream documents no way back to an older 3.1 release. In our test, Tempo 3.1.0 read the traces that 3.1.1 wrote, so to go back, deploy the previous Kix release.
