# 2026-09-19 · `kix/lib/scope/builders.nix` · A workload that names the Service selecting it (`self.svc.out.name` inside its own args) fails with a bare Nix infinite recursion and no hint at the cause.

The Service's `spec.selector = self.workload.out.selector` carries the
workload's identity, so the workload naming the Service closes a cycle.
Found four times in `kix/packages/openebs` (etcd advertise URL, the
agent-ha-cluster sidecar, NATS cluster advertise and routes). The escape
is `rawSelector` on the Service side (HANDBOOK §5.2), but nothing in the
error says so. Detecting the shape at seal time and naming both
resources in the message would save the next person the bisect.
