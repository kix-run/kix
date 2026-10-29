{ kix, packages }:

# Finished version of the cluster the docs ask you to build in
# `docs/src/content/docs/tutorials/04-first-cluster-from-scratch/`. The
# captures pipeline overlays this file onto a writable copy of
# `kix-examples/` so `kix check`, `kix build`, `kix graph`, `kix deploy`,
# etc. can run against a real 04-from-scratch cluster. Keep in sync with
# the tutorial body: if the tutorial changes the message or namespace,
# update this file (and the mutate strings in `docs/nix/captures.nix`).

kix.buildCluster {
  name = "04-from-scratch";

  modules = [
    kix.flavors.kind

    {
      namespaces = {
        tutorial-04 = { };
      };

      instances.tutorial-04 = {
        hello-world = {
          package = packages.echo-server;
          config = {
            message = "Hello from my first Kix cluster!";
          };
        };
      };
    }
  ];
}
