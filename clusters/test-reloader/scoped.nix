# Reloader as its own Kix cluster inside an existing multi-node cluster,
# watching only `reloader-demo`. It uses no flavour, so it emits nothing in
# kube-system: only its two namespaces, the ClusterRole and
# ClusterRoleBinding `reloader`, and the Activation record. Every object but
# the Namespaces, the kix.run CRDs, and the Activation carries the label
# cluster=reloader-scoped.
#
# Secrets:  kubectl create namespace reloader-demo, then the two Secrets of
#           common.nix in it.
# Deploy:   kix --flake ./clusters --context <ctx> deploy reloader-scoped -y
# Remove:   kubectl delete clusterrole,clusterrolebinding -l cluster=reloader-scoped
#           kubectl delete namespace reloader-test reloader-demo
#           kubectl delete activations.kix.run -l kix.run/cluster=reloader-scoped
#
# Without a flavour, Kix warns that no DNS instance exists and does not wait
# for DNS.
{ kix, packages }:

kix.buildCluster {
  name = "reloader-scoped";
  modules = [
    {
      cluster.capabilities.multiNode = true;
      clusterLabels.cluster = "reloader-scoped";
    }
    (import ./common.nix {
      inherit packages;
      reloaderNs = "reloader-test";
      demoNs = "reloader-demo";
      reloaderConfig.extraArgs = [ "--namespaces=reloader-demo" ];
    })
  ];
}
