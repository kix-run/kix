# cert-manager kix module — migrated from the jetstack cert-manager Helm chart (v1.19.4)
#
# Source Helm chart: jetstack/cert-manager
#
# Split into:
#   options.nix   — all option declarations (the API surface)
#   resources.nix — resource construction, helpers, and config wiring
#
# Resources produced (3 components + startup check):
#
# CONTROLLER:
#   - Deployment, Service, ServiceAccount
#   - 11 ClusterRoles (8 core + 3 aggregated view/edit/cluster-view)
#   - 8 ClusterRoleBindings
#   - 2 Roles (leader election in kube-system, tokenrequest in release namespace)
#   - 2 RoleBindings
#
# WEBHOOK:
#   - Deployment, Service, ServiceAccount
#   - ClusterRole + ClusterRoleBinding (subjectaccessreviews)
#   - Role + RoleBinding (dynamic-serving)
#   - MutatingWebhookConfiguration, ValidatingWebhookConfiguration
#
# CA INJECTOR (optional, behind cainjector.enabled):
#   - Deployment, Service, ServiceAccount
#   - ClusterRole + ClusterRoleBinding
#   - Role + RoleBinding (leader election in kube-system)
#
# STARTUP API CHECK (optional, behind startupapicheck.enabled):
#   - Job, ServiceAccount
#   - Role + RoleBinding (create certificaterequests)
#
# Total: ~41 resources with defaults.
#
# CRDs are NOT included — they are installed separately (standard practice for
# cert-manager). PSPs are also excluded (deprecated since K8s 1.25).

{
  lib,
  ...
}:

{
  imports = [
    ./options.nix
    ./resources.nix
  ];
}
