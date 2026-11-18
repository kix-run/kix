+++
kind = "changed"
packages = ["experimental/kubevirt"]
+++
`kubevirt` installs KubeVirt v1.5.1 instead of v1.5.0. The first deploy replaces virt-operator, virt-api, virt-controller, and virt-handler. Running virtual machines keep running on their v1.5.0 virt-launcher pods until they restart. The metric `kubevirt_vmi_migration_failed` no longer counts migrations in an unset phase. These now appear as `kubevirt_vmi_migrations_in_unset_phase`. KubeVirt supports upgrades only from one release to the next, so later Kix releases move `kubevirt` through v1.5.2, v1.5.3, and the latest patch of each later minor in turn. KubeVirt documents no way back. On a test cluster, deploying the older `kubevirt` package over v1.5.1 brought every component back to v1.5.0, and running virtual machines kept running.
