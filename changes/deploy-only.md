+++
kind = "added"
state = true
+++
`kix deploy <cluster> --only <namespace>/<instance>` applies one package instance, or several when repeated, in full, with every instance they need and the other objects they depend on, so a large upgrade can roll out one instance at a time. `kix plan --only` shows that part, names the instances it applies, and counts the objects of the build outside it. The cluster's current deploy record stays as it is: the new build's record is marked with the new phase `Partial`, and `status.partial` names the instances, so a later `kix deploy` without `--only` applies the rest of the build and finishes as usual. `kix status` notes each `Partial` and each `Failed` deploy record. `--only` needs a cluster that Kix has deployed before, and not from the Kix operator, and does not combine with `--prune` or `--operator`.
