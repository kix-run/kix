# 2026-11-13 · `cli/kix/src/cluster/drift.rs` · `foreign_fields` returns fields that Kix never owned, although its comment says they are the fields another manager changed.

It drops only the fields Kix's `Apply` entry still owns. A field another manager owned before Kix took the object, such as kubeadm's `data` on the CoreDNS ConfigMap, also comes back. `plan::origin::live_drift` uses it, so `kix plan` and `kix diff` can name kubeadm as a manager of drift that kubectl made. `kix status` filters its managers by the time of their last write, and the plan could use the same rule.
