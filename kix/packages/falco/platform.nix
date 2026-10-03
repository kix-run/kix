# The cluster capabilities Falco cannot run without. `default.nix` throws
# the message this returns; the unit tests call it directly, because the
# lib's own capability checks on DaemonSets and hostPath volumes refuse the
# same clusters with a generic message.
#
# Returns null when the cluster allows Falco, or the refusal message.
{ lib }:
{
  who,
  capabilities,
  provider ? null,
}:
let
  missing = builtins.filter (cap: (capabilities.${cap} or null) == false) [
    "daemonSets"
    "privilegedContainers"
  ];
  on = if provider == null then "" else " (provider ${provider})";
in
if missing == [ ] then
  null
else
  "${who}: cluster.capabilities sets ${
    lib.concatMapStringsSep " and " (cap: "${cap} = false") missing
  }${on}. Falco runs a DaemonSet on every node with host mounts and the BPF, PERFMON, SYS_RESOURCE, and SYS_PTRACE capabilities, which this cluster does not allow. GKE Autopilot forbids both. Remove the falco instance, or run it on a cluster that allows node agents."
