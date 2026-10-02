# 2026-10-02 · `kix/lib/plugins/availability` · A one-node kind cluster resolves availability to `none`, so test clusters never render the multi-replica defaults.

The substrate check caps kind at `none`, so every `kix.availability.pick` default gives one replica there. `clusters/test-harbor.nix` sets `jobservice.replicas = 2` by hand to prove that a job log is served by a pod that did not run the job. Other packages whose correctness depends on running two pods get no such coverage on kind unless their test cluster does the same.
