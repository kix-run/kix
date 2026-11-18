+++
kind = "changed"
packages = ["experimental/mayastor"]
+++
`mayastor` moves from 2.12.1 to 2.12.2, a patch release. Upstream's control-plane and io-engine code is the same in both releases, and the images have new digests. A deploy restarts the control-plane pods on the new images. The io-engine pods keep their 2.12.1 image until you delete each one, one node at a time after volume rebuilds finish, and the deploy reports them as pending a restart. Upstream does not document a move back to 2.12.1, and that move has not been tested.
