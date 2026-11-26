# Kix

Kix is a Kubernetes compiler. You define packages and clusters in Nix, evaluate and check the whole cluster locally before touching Kubernetes, preview the package-level plan against live state, and deploy in dependency order.

The output is standard Kubernetes manifests. Because Kix builds the cluster from one explicit dependency graph, it uses the same model for deploy order, network policy, ownership, policy checks, diffs, and change impact.

A minimal `cluster.nix` installing one package instance on a local `kind` cluster:

```nix
{ kix, packages }:

kix.buildCluster {
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
```

## Install

Install Kix on `x86_64-linux`, `aarch64-linux`, or `aarch64-darwin`:

```sh
curl -fsSL https://kix.run/install | sh
```

The script verifies the release archive, unpacks Kix and the Kix runtime (including Nix, Helm, `kubectl`, and `sops`) to `~/.local/share/kix/<version>/`, and links `~/.local/bin/kix` without editing shell startup files. Run `kix doctor` to verify the installation.

To try Kix on a local `kind` cluster using [kix-examples](https://github.com/kix-run/kix-examples), start with the [tutorials](https://kix.run/docs/tutorials/). For release archive downloads and per-project version pinning, see [Install and run Kix](https://kix.run/docs/how-to/start-and-inspect/install-and-run-the-kix-cli/).

## Documentation

Full documentation is at [kix.run/docs](https://kix.run/docs/):

- [Tutorials](https://kix.run/docs/tutorials/): step-by-step lessons that build a working local cluster one concept at a time.
- [How-to guides](https://kix.run/docs/how-to/): focused recipes for operating clusters, authoring packages, wiring dependencies, adopting existing resources, and running Kix in CI.
- [Reference](https://kix.run/docs/reference/): schema, builder, helper, scorecard, and `kix` command reference.
- [Explanation](https://kix.run/docs/explanation/): how the dependency graph, personas, network policy compiler, availability levels, scorecards, and server-side apply work together.

## Status

Kix is below 1.0 and uses semantic versioning. A minor release may contain breaking changes, listed in [CHANGELOG.md](CHANGELOG.md). Projects pin their version of Kix in `flake.lock`, and `kix` runs the pinned version automatically. Packages are split between [`kix/packages/stable/`](kix/packages/stable/) and [`kix/packages/experimental/`](kix/packages/experimental/).

## Repository

- [`cli/`](cli/): Rust source for `kix` and the operator
- [`kix/lib/`](kix/lib/): the Kix library
- [`kix/packages/`](kix/packages/): `stable/` and `experimental/` package definitions
- [`docs/`](docs/): documentation site

Kix is developed largely by AI coding agents directed and reviewed by its two maintainers. [`v2_discussions/`](v2_discussions/) holds the design documents, and [`housekeeping/`](housekeeping/) is the agents' log of known problems.

## Feedback and bugs

Questions and feedback go to [GitHub Discussions](https://github.com/kix-run/kix/discussions). Bug reports go to [GitHub Issues](https://github.com/kix-run/kix/issues).

## License

Apache License 2.0. See [LICENSE](LICENSE).
