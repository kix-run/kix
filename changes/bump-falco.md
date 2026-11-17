+++
kind = "note"
packages = ["experimental/falco"]
+++
`experimental/falco` now runs Falco 0.45.2 in place of 0.45.0. The first deploy after you upgrade replaces each Falco pod once. On Linux 6.18.59, the 0.45.0 image crash-loops because its modern eBPF probe fails to load, and 0.45.2 loads it. To go back, deploy the previous version of the package.
