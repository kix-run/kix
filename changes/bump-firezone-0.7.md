+++
kind = "changed"
packages = ["experimental/firezone"]
+++
`firezone` now runs Firezone 0.7.36 instead of 0.7.26. 0.7.36 is the last release of the 0.7 line, and upstream publishes no fixes for it. Your definition needs no change. The first deploy restarts the Firezone pod once. The database needs no migration. To go back, deploy the previous Kix version, which runs 0.7.26 on the same database.
