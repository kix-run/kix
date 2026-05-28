# Live command output manifest — declares the kix commands whose output we
# want captured against a real Kubernetes cluster.
#
# Same shape as `command-outputs-manifest.nix`, plus per-command ordering: the
# regen script runs every command in order inside a freshly-created kind
# cluster, captures stdout/stderr/exitCode, sanitises through the transforms
# pipeline, and writes JSON sidecars next to the offline ones under
# `docs/src/command-output/`.
#
# Sequencing rule: commands run in array order. A command both produces a
# captured JSON sidecar AND advances cluster state for subsequent commands —
# so e.g. listing the first entry as `kix deploy` makes the rest of the group
# observe a deployed cluster.
#
# Trust boundary: the regen script will refuse to run unless its KUBECONFIG
# names exactly `kind-kix-docs`. See `docs/nix/live-command-outputs.nix`.

[
  {
    group = "tutorials/02-hello-world";
    page = "/docs/tutorials/02-local-setup-and-first-run/";
    cwd = "kix-examples/";
    commands = [
      {
        name = "deploy";
        args = [
          "deploy"
          "02-hello-world"
          "-y"
        ];
      }
      {
        name = "status";
        args = [
          "status"
          "02-hello-world"
        ];
      }
      {
        name = "kubectl-get-pods";
        cmd = "kubectl";
        args = [
          "get"
          "pods"
          "-n"
          "tutorial-02"
        ];
      }
      {
        name = "kubectl-get-svc";
        cmd = "kubectl";
        args = [
          "get"
          "svc"
          "-n"
          "tutorial-02"
        ];
      }
    ];
  }
]
