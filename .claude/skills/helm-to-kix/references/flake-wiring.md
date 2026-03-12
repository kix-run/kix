# Wiring a New Package into flake.nix

## Step 1: Import the package

At the top of the `perSystem` let block, add:

```nix
importMyChart = import ./pkgs-fp/my-chart { inherit k8s lib; };
```

## Step 2: Add chartVariants entries

In the `chartVariants` attrset, add at minimum the base variant plus any interesting feature combinations:

```nix
chartVariants = {
  # ... existing variants ...

  # Base (all defaults)
  my-chart = importMyChart;

  # Feature variants — test that optional features produce valid schemas
  my-chart-with-metrics = importMyChart.override {
    metrics = { enabled = true; /* ... full attrset ... */ };
  };
};
```

Each variant automatically gets:
- `nix build .#<variant-name>` (manifest directory)
- `nix flake check` schema validation via kubeconform

## Step 3: Add to a test cluster

### Minimal test (clusters/test-minimal.nix or a new test file)
Test with pure defaults — validates no extra resources leak.

### Full test (clusters/test-full.nix)
Enable all features — validates feature interaction.

### Example cluster (clusters/example.nix)
Add a realistic production-like configuration:

```nix
my-chart = (import ../pkgs-fp/my-chart { inherit k8s lib; }).override {
  namespace = "my-namespace";
  inherit clusterLabels;
  # ... production-like overrides ...
};
```

## Step 4: Add check assertions

In `flake.nix` `checks`, add assertions for each cluster that includes the new package:

```nix
# In the cluster-example check:
assert manifests ? "my-chart-deployment";
assert manifests ? "my-chart-service";
assert manifests ? "my-chart-serviceaccount";
# Negative assertions for disabled features:
assert !(manifests ? "my-chart-horizontalpodautoscaler");
```

Manifest keys follow the pattern: `"{resource-name}-{lowercase-kind}"`.
Examples: `"coredns-deployment"`, `"valkey-node-statefulset"`, `"cert-manager-webhook-service"`.

## Step 5: Validate

```bash
# Build the package
nix build .#my-chart

# Inspect output
ls result/
cat result/my-chart-deployment.yaml

# Run all checks (schema + assertions + cross-resource validation)
nix flake check

# Visualize the DAG (if added to example cluster)
nix eval --raw .#legacyPackages.aarch64-darwin.fpClusterExample.dagTree
```

## Override completeness warning

`.override` uses shallow `//` on the defaults attrset. This means:

```nix
# This REPLACES the entire sentinel attrset:
importValkey.override {
  sentinel = {
    enabled = true;
    # Must include ALL sentinel fields, not just enabled
    quorum = 2;
    primarySet = "myprimary";
    # ... every field ...
  };
};
```

If you only provide `{ enabled = true; }`, all other sentinel fields will be missing (no defaults from the `?` in the function signature — those only apply when the entire `sentinel` arg is absent).
