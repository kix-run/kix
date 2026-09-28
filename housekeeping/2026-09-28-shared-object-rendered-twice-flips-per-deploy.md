# 2026-09-28 · `cli/kix/src/cluster/apply.rs` · An object two Kix clusters render differently is rewritten by whichever deployed last.

Two Kix clusters on one Kubernetes cluster that both deploy a ClusterRole of
the same name, from package instances in differently named namespaces, render
different `kix.run/package-namespace` annotations and so different identity
hashes. Each deploy re-applies the object with its own copy, and `kix diff`
for the other cluster then reports that package's resource as removed from
one package and added to another. Nothing warns that two builds disagree
about one object. Seen with a kind demo of two echo-server clusters sharing
`ClusterRole/sweep-demo-reader`.
