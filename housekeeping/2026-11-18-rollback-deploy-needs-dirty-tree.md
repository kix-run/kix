# Going back to an older package version needs a deploy from a dirty tree

Testing a rollback meant restoring the old package file as an uncommitted
edit, then running `kix deploy monitoring-loki`. The repo's rule is to
commit before each deploy, because a deploy from uncommitted changes is
recorded as dirty. The rollback deploy was the only way to get the old
package onto the cluster, so the rule and the test could not both hold.

Kix could let a test name a package version to deploy from a git ref,
such as a commit, without a working-tree edit. Or the deploy could record
the commit the old file came from. Either would make the rollback test
clean. Found while bumping `experimental/loki` from 3.7.8 to 3.7.10 on a
kind cluster.
