# Test clusters that exercise Kix features.
#
# Build:  nix build .#cluster-minimal --extra-experimental-features pipe-operators
#
# Note: test-helm is excluded because it references ../tests/helm-test-chart, which is
# outside this flake tree. Build it from the root flake instead.

{
  description = "kix test clusters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    kix.url = "path:../kix";
  };

  outputs =
    inputs:
    inputs.kix.lib.mkFlake {
      inherit inputs;
      # Every cluster here runs the full built-in rule set, which is the
      # shipped default, with the severity cap raised: a finding an
      # error-severity rule makes fails the build in this repository.
      clusterModules = [ { scorecard.maxSeverity = "error"; } ];

      # region:pinFile
      # Declared once. A cluster that takes a `pins` argument gets this file
      # already loaded, so no cluster definition names the path.
      pins = ./pins.json;
      # endregion:pinFile

      clusters = {
        minimal = ./test-minimal.nix;
        example = ./example.nix;
        full = ./test-full.nix;
        example-import = ./example-import.nix;
        auto = ./test-auto.nix;
        auto2 = ./test-auto2.nix;
        immich = ./test-immich.nix;
        n8n = ./test-n8n.nix;
        clickhouse = ./test-clickhouse.nix;
        clickhouse-operator = ./test-clickhouse-operator.nix;
        clickhouse-swap-bare = ./test-clickhouse-swap/bare.nix;
        clickhouse-swap-replicated = ./test-clickhouse-swap/replicated.nix;
        kind = ./test-kind.nix;
        spread = ./test-spread.nix;
        monitoring-native = ./test-monitoring-native.nix;
        monitoring-loki = ./test-monitoring-loki.nix;
        test-secrets = ./test-secrets.nix;
        victoria-metrics = ./test-victoria-metrics.nix;
        kind-probe = ./test-kind-probe.nix;
        pins = ./test-pins.nix;
        fragments = ./test-fragments.nix;
        multi-env = ./test-multi-env.nix;
        doc-how-tos = ./test-doc-how-tos.nix;
        harbor = ./test-harbor.nix;
        operators = ./test-operators.nix;
        sealed-jobs = ./test-sealed-jobs.nix;
        ingress-netpol = ./test-ingress-netpol.nix;
        rke2-cilium = ./test-rke2-cilium.nix;
        external-dns = ./test-external-dns.nix;
        external-dns-tryout = ./test-external-dns-tryout.nix;
        velero = ./test-velero.nix;
        reloader = ./test-reloader/kind.nix;
        tailscale = ./test-tailscale/cluster.nix;
        mayastor = ./test-mayastor.nix;
        virtualization = ./test-virtualization.nix;
        metabase = ./test-metabase.nix;
        metrics-server = ./test-metrics-server.nix;
        monitoring-netpol = ./test-monitoring-netpol.nix;
      };
    };
}
