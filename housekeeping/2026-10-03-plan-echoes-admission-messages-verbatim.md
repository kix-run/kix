# 2026-10-03 · `kix/src/cluster/preview.rs` · Plan refusal messages repeat what a webhook or policy says, and that can quote a Secret's value.

`Refusal::of_status` keeps the apiserver's message as it is. Core validation
redacts Secret values, but a Kyverno message, a Gatekeeper `msg`, or a
ValidatingAdmissionPolicy `messageExpression` can interpolate `object.data`.
The message then reaches the text, JSON, and Markdown plan, which CI may post.
