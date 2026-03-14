So to actually deploy a cluster based on this, what is the ideal 
flow? Not all of it has to be present at this stage, but this is the ideal:

# Desires

## Critical

- ~~Manifest rendering~~ (Done)
- Conversion of Helm charts (Tentatively done for small-to-medium-sized charts)

## Important

- Plan for ongoing maintenance of converted Helm charts, and merging in of upstream changes (could just be a couple of claude skills?)
- YAML application order (via DAG) - eg `0085-coredns-service.yaml`, would be a crude example
- Multi-deployments per cluster / per namespace (not required for base setup)

## Nice to have

- Integration with Nix (i.e. can configure system and deploy k8s with one command)
- Integrated cli (`kix diff`, to diff against a running cluster)
- Diff against a local dump of the cluster

# The flow

## v1

- Generate manifests
- `kubectl apply -f results/`

## v2

- `kix diff` - Diff against the live cluster
- `kix apply [--dry-run]` - Apply it all, option to dry run against api server
- `kix apply --wait` - Wait for each Package Set to become ready before deploying 
  (or something smarter, only deploy a think when its dependencies are ready)