# 2026-11-24 · `kix/lib/eval/validate.nix` · A HorizontalPodAutoscaler and a KEDA ScaledObject on the same workload are not refused.

Two autoscalers on one Deployment fight over `spec.replicas`. KEDA's
admission webhook refuses a ScaledObject whose target already has an HPA,
but its failurePolicy is Ignore, so a deploy made while the webhook is not
answering admits it. The build holds both objects and could refuse the pair,
as `validate.nix` already refuses an HPA whose target no resource
creates.
