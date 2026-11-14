+++
kind = "fixed"
cli = ["kix history"]
+++
`kix history` marked every earlier deploy `build not on this machine`, even a
build made on this machine minutes before. It now looks for the build where
`kix rollback` looks, so it marks a deploy `available` when a rollback can
restore it, and says `build on this machine does not load` when it finds a build
it cannot read. Kix now says that objects that left the build are "still on the
cluster" because many of them, such as a finished Job, do not run. The `[K6054]`
refusal for `kix lib update` now also says that a project using a development
library has nothing to update.
