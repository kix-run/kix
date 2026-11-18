# clusters/test-stackgres-operator.nix: the StackGres operator with one
# PostgreSQL cluster, under Cilium default-deny.
#
# `data/pg` is a one-instance stackgres-cluster, the operator's dependent
# here. A version bump of the operator is tested by writing rows into it on
# the old operator and reading them back on the new one.
#
# Build:  kix build stackgres-operator
# Deploy: kix deploy stackgres-operator --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

kix.buildCluster {
  name = "test-stackgres-operator";
  modules = [
    kix.flavors.kind
    {
      networkPolicy.enable = true;

      # kind runs with the default CNI disabled, so the managed cilium
      # instance fills the cni role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      instances.kube-system.cilium.package = packages.experimental.cilium;

      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

      instances.data.pg = {
        package = packages.experimental.stackgres-cluster;
        config.instances = 1;
      };
    }
  ];
}
