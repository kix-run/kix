# Captures manifest — declares the commands the docs pipeline runs to
# generate sidecar JSON for `<Command>`. One manifest, two execution
# modes:
#
#   - offline steps run in a Nix sandbox against a workspace derived
#     from `kix-examples` (+ optional overlay + setup mutations).
#   - live steps run as a shell script (`nix run ./docs#regen-captures`)
#     against the dedicated `kind-kix-docs` kind cluster.
#
# Per-group fields:
#
#   group     — identifier; sidecar paths go to docs/src/command-output/<group>/<name>.json
#   page      — docs URL the sidecars belong to (carried in the JSON for tooling)
#   cwd       — working directory shown in the `<Command>` chrome
#   overlay   — optional directory `cp -r`'d onto the workspace (e.g. adds
#               a tutorial's finished cluster file). Layout mirrors
#               kix-examples/. See docs/overlays/README.md.
#   setup     — list of `mutate` steps applied once after the workspace
#               is prepared (e.g. patch flake.nix to register an overlay
#               cluster). Runs for BOTH offline and live pipelines.
#   offline   — list of steps the offline driver executes.
#   live      — list of steps the live driver executes.
#
# Step shapes:
#
#   { capture = "name"; run = [ "kix" "list" "clusters" ]; sortLines = false;
#     allowFailure = false; skipDriftCheck = false; }
#       runs the command in the workspace, sanitises stdout/stderr,
#       writes docs/src/command-output/<group>/name.json. By default a
#       non-zero exit fails the whole pipeline so regressions surface;
#       set `allowFailure = true` to record the failure as a sidecar
#       (used for tutorials that demonstrate an intentional error).
#       `skipDriftCheck = true` exempts the capture from the --check
#       drift comparison entirely. Useful when the output is dominated
#       by environment-specific noise the drift transforms can't
#       reasonably redact (Nix-version-specific eval-error stack
#       traces, etc.). --apply still rewrites the sidecar; --check
#       just doesn't gate on its content.
#
#   { mutate = { file = "tutorial-04/cluster.nix";
#                oldString = "Hello"; newString = "Preview"; }; }
#       literal substitution against workspace/<file>. Preflight checks:
#       file must exist, oldString must match exactly once. Fails the
#       whole capture run on any preflight miss (no partial sidecars).
#
# Sequencing:
#   - Offline: each group gets its own fresh workspace. Steps run in
#     declaration order. No shared cluster.
#   - Live: each group gets its own fresh workspace, but the kind
#     cluster is shared across groups so deploys accumulate (matching
#     a reader walking the tutorial path).

[
  {
    group = "tutorials/02-hello-world";
    page = "/docs/tutorials/02-local-setup-and-first-run/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "list-clusters";
        run = [
          "kix"
          "list"
          "clusters"
        ];
      }
      {
        capture = "list-packages";
        run = [
          "kix"
          "list"
          "packages"
          "--cluster"
          "02-hello-world"
        ];
      }
    ];
    live = [
      {
        capture = "kubectl-cluster-info";
        run = [
          "kubectl"
          "cluster-info"
        ];
      }
      {
        capture = "kubectl-get-nodes";
        run = [
          "kubectl"
          "get"
          "nodes"
        ];
      }
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "02-hello-world"
          "-y"
        ];
      }
      {
        capture = "status";
        run = [
          "kix"
          "status"
          "02-hello-world"
        ];
      }
      {
        capture = "kubectl-get-pods";
        run = [
          "kubectl"
          "get"
          "pods"
          "-n"
          "tutorial-02"
        ];
      }
      {
        capture = "kubectl-get-svc";
        run = [
          "kubectl"
          "get"
          "svc"
          "-n"
          "tutorial-02"
        ];
      }
      {
        # Tutorial 02's "Make One Edit" section — change the message in
        # the checked-in cluster file, then re-deploy.
        mutate = {
          file = "tutorials/02-hello-world/cluster.nix";
          oldString = ''message = "Hello from Kix!";'';
          newString = ''message = "Hello from my laptop!";'';
        };
      }
      {
        capture = "deploy-after-edit";
        run = [
          "kix"
          "deploy"
          "02-hello-world"
          "-y"
        ];
      }
    ];
  }

  {
    # Tutorial 04 / 05 operate on 04-from-scratch, which the reader
    # builds themselves under tutorial-04/. The overlay adds the
    # finished cluster file; the setup patches kix-examples/flake.nix
    # to register it. From here both pipelines treat 04-from-scratch
    # as a first-class cluster.
    group = "tutorials/04-from-scratch";
    page = "/docs/tutorials/04-first-cluster-from-scratch/";
    cwd = "kix-examples/";
    overlay = ../overlays/04-from-scratch;
    setup = [
      {
        # NOTE: the leading whitespace on the second line must match
        # the indentation of the `clusters = { ... };` block in
        # kix-examples/flake.nix. If that file gets reformatted, the
        # mutate's no-match preflight will fail and this string needs
        # updating.
        mutate = {
          file = "flake.nix";
          oldString = ''"19-scorecards" = ./tutorials/19-scorecards/cluster.nix;'';
          newString = ''
            "19-scorecards" = ./tutorials/19-scorecards/cluster.nix;
                    "04-from-scratch" = ./tutorial-04/cluster.nix;'';
        };
      }
    ];
    offline = [
      {
        capture = "list-clusters";
        run = [
          "kix"
          "list"
          "clusters"
        ];
      }
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "04-from-scratch"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "04-from-scratch"
        ];
      }
      {
        capture = "graph-tree";
        run = [
          "kix"
          "graph"
          "04-from-scratch"
          "--format"
          "tree"
        ];
      }
    ];
    live = [
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "04-from-scratch"
          "-y"
        ];
      }
      {
        capture = "diff-clean";
        run = [
          "kix"
          "diff"
          "04-from-scratch"
        ];
        # kix diff exits non-zero when drift exists, which is the
        # whole point of capturing it here.
        allowFailure = true;
      }
      {
        # Tutorial 05's "make a visible edit" — change the message in
        # the cluster file the reader just built.
        mutate = {
          file = "tutorial-04/cluster.nix";
          oldString = ''message = "Hello from my first Kix cluster!";'';
          newString = ''message = "Preview this before deploy.";'';
        };
      }
      {
        capture = "diff-after-edit";
        run = [
          "kix"
          "diff"
          "04-from-scratch"
        ];
        allowFailure = true;
      }
      {
        capture = "deploy-after-edit";
        run = [
          "kix"
          "deploy"
          "04-from-scratch"
          "-y"
        ];
      }
      {
        capture = "status";
        run = [
          "kix"
          "status"
          "04-from-scratch"
        ];
      }
      {
        capture = "kubectl-get-pods";
        run = [
          "kubectl"
          "get"
          "pods"
          "-n"
          "tutorial-04"
        ];
      }
      {
        capture = "kubectl-get-svc";
        run = [
          "kubectl"
          "get"
          "svc"
          "-n"
          "tutorial-04"
        ];
      }
    ];
  }

  {
    group = "tutorials/06-service-dep";
    page = "/docs/tutorials/06-first-local-package-and-service-to-service-dependency/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "06-service-dep"
        ];
      }
      {
        capture = "graph-tree";
        run = [
          "kix"
          "graph"
          "06-service-dep"
          "--format"
          "tree"
        ];
      }
      {
        # Tutorial 06's "Try Breaking The Name Match" section —
        # rename `backend` to `api` so the gateway package's
        # `backend` dep no longer resolves. `kix check` should fail
        # with an unresolved-dep error; we capture that failure as
        # the sidecar, then revert the rename so later steps see a
        # clean cluster.
        mutate = {
          file = "tutorials/06-service-dep/cluster.nix";
          oldString = "backend = {";
          newString = "api = {";
        };
      }
      {
        capture = "check-broken-name";
        run = [
          "kix"
          "check"
          "06-service-dep"
        ];
        allowFailure = true;
        # The captured output is a Nix eval-error stack trace, and
        # different Nix versions render it differently (line numbers,
        # `derivationStrict` vs `drvFunc`, flake-ref display).
        # That noise is too varied to redact, so just don't gate
        # CI on this sidecar's content.
        skipDriftCheck = true;
      }
      {
        mutate = {
          file = "tutorials/06-service-dep/cluster.nix";
          oldString = "api = {";
          newString = "backend = {";
        };
      }
    ];
    live = [
      {
        capture = "deploy";
        run = [
          "kix"
          "deploy"
          "06-service-dep"
          "-y"
        ];
      }
    ];
  }

  {
    group = "tutorials/19-scorecards";
    page = "/docs/tutorials/19-scorecards-and-compile-time-policy/";
    cwd = "kix-examples/";
    offline = [
      {
        capture = "check";
        run = [
          "kix"
          "check"
          "19-scorecards"
        ];
      }
      {
        capture = "build";
        run = [
          "kix"
          "build"
          "19-scorecards"
        ];
      }
    ];
  }
]
