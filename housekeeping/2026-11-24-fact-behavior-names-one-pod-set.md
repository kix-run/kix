# 2026-11-24 · `kix/lib/plugins/netpol/derive.nix` · A CRD's `factBehavior` names one set of pods for every address in the spec.

A custom resource whose spec holds addresses for two different dialers gets
all of them on the one `podSelector`. KEDA's ScaledJob is the case: its
triggers are dialled by the KEDA operator, and its `jobTargetRef` pod
template is a Job the operator starts. A Service address in that template
opens the operator's egress, which it never uses, and the Job pods get no
policy, so under default deny they cannot reach it. The keda package states
this in its header. Fixing it needs `factBehavior` to map spec paths to pod
sets, or the template's facts to reach a policy on the Job pods' labels.
