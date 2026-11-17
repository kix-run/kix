+++
kind = "fixed"
packages = ["experimental/falco"]
+++
`falco` now runs Falco 0.45.2 instead of 0.45.0. On Linux 6.18, Falco 0.45.0 crash-loops because the kernel refuses to load its eBPF probe. Falco 0.45.2 loads it and runs. The first deploy after you upgrade replaces each Falco pod once. Going back to 0.45.0 brings the crash loop back on Linux 6.18.
