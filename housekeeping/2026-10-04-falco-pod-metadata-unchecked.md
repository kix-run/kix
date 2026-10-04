# 2026-10-04 · `kix/packages/falco` · Nobody has checked that Falco's alerts carry the pod name on Kubernetes, or that it starts on SELinux-enforcing nodes.

`clusters/test-falco.nix` deployed on kind on 2026-10-04 (kernel 6.12), so the capability set opens the modern BPF probe under a pod's seccomp profile. Still unproven: whether the CRI engine fills `k8s.pod.name` in alerts, behaviour with `perf_event_paranoid` at 3 or above, and SELinux-enforcing nodes without `privileged`. Deploy on kind with `--keep`, exec a shell into a pod, and read the alert Falco logs.
