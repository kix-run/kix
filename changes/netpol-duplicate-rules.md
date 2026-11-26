+++
kind = "changed"
+++
A generated workload policy now writes each rule once when two sources ask for the same one, such as a package's own egress to the internet on port 443 and its cloud identity's credential egress. The policies allow the same traffic, so the first deploy after the upgrade applies the affected policies again.
