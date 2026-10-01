# Reloader on a four-node kind cluster (scripts/kind-spread-config.yaml):
# two reloader replicas with one leader, and the demo Deployments from
# common.nix.
#
# Bring up: kind create cluster --name kix-reloader --config scripts/kind-spread-config.yaml
# Secrets:  kubectl create namespace demo
#           kubectl -n demo create secret generic demo-token --from-literal=token=a
#           kubectl -n demo create secret generic demo-other --from-literal=token=a
# Deploy:   kix --flake ./clusters --context kind-kix-reloader deploy reloader -y
# Rotate:   kubectl -n demo patch secret demo-token -p '{"stringData":{"token":"b"}}'
#           restarts web, not web2.
{ kix, packages }:

kix.buildCluster {
  name = "reloader";
  modules = [
    kix.flavors.kind
    { cluster.capabilities.multiNode = true; }
    (import ./common.nix {
      inherit packages;
      reloaderNs = "reloader";
      demoNs = "demo";
      reloaderConfig = { };
    })
  ];
}
