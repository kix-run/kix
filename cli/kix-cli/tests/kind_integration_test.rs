//! Integration test against a real kind cluster.
//!
//! Requires: `kind` and `kubectl` on PATH, Nix FFI available.
//! Creates a temporary kind cluster, deploys the `kind` cluster definition
//! (echo-server in its own namespace — no conflicts with kind's built-ins),
//! verifies deploy, local DAG diff, soft GC, and hard GC.
//!
//! Run with: cargo test --test kind_integration_test -- --ignored
//! (ignored by default because it requires kind + is slow)

use kix::manifest::keys;
use std::path::Path;
use std::process::Command;

fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
}

fn kix(kind_cluster: &str) -> assert_cmd::Command {
    let mut cmd = assert_cmd::Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd.args(["--context", &format!("kind-{kind_cluster}")]);
    cmd.current_dir(repo_root());
    cmd
}

fn has_kind() -> bool {
    Command::new("kind").arg("version").output().is_ok()
}

fn has_kubectl() -> bool {
    Command::new("kubectl")
        .arg("version")
        .arg("--client")
        .output()
        .is_ok()
}

fn kind_create(name: &str) -> bool {
    Command::new("kind")
        .args(["create", "cluster", "--name", name])
        .output()
        .is_ok_and(|o| o.status.success())
}

fn kind_delete(name: &str) {
    let _ = Command::new("kind")
        .args(["delete", "cluster", "--name", name])
        .output();
}

fn kubectl(context: &str, args: &[&str]) -> std::process::Output {
    Command::new("kubectl")
        .arg("--context")
        .arg(context)
        .args(args)
        .output()
        .expect("kubectl should work")
}

fn kubectl_stdout(context: &str, args: &[&str]) -> String {
    let output = kubectl(context, args);
    String::from_utf8_lossy(&output.stdout).to_string()
}

/// Clear the activation cache for a kix cluster name so the next deploy
/// sees no previous state. The cache persists across kind cluster recreations.
fn clear_activation_cache(kix_cluster: &str) {
    if let Ok(home) = std::env::var("HOME") {
        let activation_file =
            Path::new(&home).join(format!(".cache/kix/activations/{kix_cluster}.path"));
        let _ = std::fs::remove_file(&activation_file);
    }
}

const KIND_CLUSTER: &str = "kix-integration";
const KUBE_CTX: &str = "kind-kix-integration";
/// The kix cluster name (from clusters/test-kind.nix, registered as "kind" in flake.nix)
const KIX_CLUSTER: &str = "kind";

#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn deploy_and_gc() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }

    // Ensure clean state
    kind_delete(KIND_CLUSTER);
    clear_activation_cache(KIX_CLUSTER);

    if !kind_create(KIND_CLUSTER) {
        panic!("failed to create kind cluster");
    }

    // Always clean up the kind cluster
    struct CleanupGuard;
    impl Drop for CleanupGuard {
        fn drop(&mut self) {
            kind_delete(KIND_CLUSTER);
        }
    }
    let _guard = CleanupGuard;

    // =========================================================================
    // Phase 1: First deploy — everything created
    // =========================================================================
    eprintln!("\n=== Phase 1: First deploy ===");

    let first = kix(KIND_CLUSTER)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .expect("deploy command should run");

    let stdout1 = String::from_utf8_lossy(&first.stdout);
    eprintln!("{stdout1}");

    assert!(first.status.success(), "first deploy should succeed");
    assert!(stdout1.contains("created"), "should create resources");
    assert!(
        stdout1.contains("No previous activation"),
        "should detect no previous activation"
    );

    // Verify resources on cluster
    let managed = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "all,configmap",
            "-n",
            "echo",
            "-l",
            "app.kubernetes.io/managed-by=kix",
            "-o",
            "name",
        ],
    );
    eprintln!("Managed resources:\n{managed}");
    assert!(!managed.trim().is_empty(), "should have managed resources");

    // =========================================================================
    // Phase 2: Second deploy — local DAG diff, everything unchanged
    // =========================================================================
    eprintln!("\n=== Phase 2: Second deploy (DAG diff) ===");

    let second = kix(KIND_CLUSTER)
        .args(["deploy", KIX_CLUSTER, "--yes"])
        .output()
        .expect("second deploy should run");

    let stdout2 = String::from_utf8_lossy(&second.stdout);
    eprintln!("{stdout2}");

    assert!(second.status.success(), "second deploy should succeed");
    assert!(
        stdout2.contains("Everything up to date"),
        "should detect everything unchanged via local DAG diff"
    );
    assert!(
        stdout2.contains("Loading previous activation"),
        "should load cached activation"
    );

    // =========================================================================
    // Phase 3: Soft GC — no garbage (same activation)
    // =========================================================================
    eprintln!("\n=== Phase 3: Soft GC (no garbage expected) ===");

    let gc_soft = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--yes"])
        .output()
        .expect("soft gc should run");

    let gc_soft_out = String::from_utf8_lossy(&gc_soft.stdout);
    eprintln!("{gc_soft_out}");

    assert!(gc_soft.status.success(), "soft gc should succeed");
    assert!(
        gc_soft_out.contains("No garbage found"),
        "soft gc should find no garbage when nothing changed, got:\n{gc_soft_out}"
    );

    // =========================================================================
    // Phase 4: Hard GC — no garbage (all resources match expected set)
    // =========================================================================
    eprintln!("\n=== Phase 4: Hard GC (no garbage expected) ===");

    let gc_hard = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--hard", "--yes"])
        .output()
        .expect("hard gc should run");

    let gc_hard_out = String::from_utf8_lossy(&gc_hard.stdout);
    eprintln!("{gc_hard_out}");

    assert!(gc_hard.status.success(), "hard gc should succeed");
    assert!(
        gc_hard_out.contains("No garbage found"),
        "hard gc should find no garbage when cluster matches expected state, got:\n{gc_hard_out}"
    );

    // =========================================================================
    // Phase 5: Hard GC — detect manually created orphan
    // =========================================================================
    eprintln!("\n=== Phase 5: Hard GC (detect orphan) ===");

    // Create a ConfigMap with kix labels that's NOT in the activation
    let create_result = kubectl(
        KUBE_CTX,
        &[
            "create",
            "configmap",
            "orphan-test",
            "-n",
            "echo",
            "--from-literal=key=value",
        ],
    );
    assert!(
        create_result.status.success(),
        "should create test configmap"
    );

    // Label it as kix-managed so hard GC picks it up
    let label_result = kubectl(
        KUBE_CTX,
        &[
            "label",
            "configmap",
            "orphan-test",
            "-n",
            "echo",
            "app.kubernetes.io/managed-by=kix",
        ],
    );
    assert!(label_result.status.success(), "should label configmap");

    // Annotate with a fake identity-hash that won't match any expected resource
    let annotate_result = kubectl(
        KUBE_CTX,
        &[
            "annotate",
            "configmap",
            "orphan-test",
            "-n",
            "echo",
            &format!("{}=fake00000000orphan000000000000", keys::IDENTITY_HASH),
        ],
    );
    assert!(
        annotate_result.status.success(),
        "should annotate configmap"
    );

    // Hard GC should now detect this as garbage
    let gc_orphan = kix(KIND_CLUSTER)
        .args(["gc", KIX_CLUSTER, "--hard", "--yes"])
        .output()
        .expect("hard gc with orphan should run");

    let gc_orphan_out = String::from_utf8_lossy(&gc_orphan.stdout);
    eprintln!("{gc_orphan_out}");

    assert!(
        gc_orphan_out.contains("orphan-test"),
        "hard gc should detect the orphan-test configmap as garbage, got:\n{gc_orphan_out}"
    );
    assert!(
        gc_orphan_out.contains("deleted"),
        "hard gc should delete the orphan, got:\n{gc_orphan_out}"
    );

    // Verify orphan is gone
    let check_orphan = kubectl_stdout(
        KUBE_CTX,
        &[
            "get",
            "configmap",
            "orphan-test",
            "-n",
            "echo",
            "--ignore-not-found",
            "-o",
            "name",
        ],
    );
    assert!(
        check_orphan.trim().is_empty(),
        "orphan-test should be deleted from cluster"
    );

    eprintln!("\n=== All phases passed ===");
}

// =============================================================================
// Two Kix clusters in one Kubernetes cluster
// =============================================================================

/// A flake with Kix clusters `sweep-a` and `sweep-b`, echo servers in
/// namespaces of their own, both deploying the `shared-role` package into
/// the namespace `shared`: a ClusterRole and a ConfigMap.
struct TwoClusters {
    dir: tempfile::TempDir,
}

const SHARED_ROLE_NIX: &str = r#"{ scope, ... }:
{
  meta = {
    version = "1";
    description = "Objects both test clusters deploy";
    owner = "test";
  };
  build =
    { self, ... }:
    {
      role = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "sweep-test-reader";
        extra.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [ "get" ];
          }
        ];
      };
      note = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "sweep-test-shared";
        extra.data.owner = "both";
      };
      root = self.role;
    };
}
"#;

impl TwoClusters {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let lock: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(repo_root().join("flake.lock")).unwrap())
                .unwrap();
        let rev = lock["nodes"]["nixpkgs"]["locked"]["rev"].as_str().unwrap();
        let flake = format!(
            r#"{{
  inputs = {{
    nixpkgs.url = "github:NixOS/nixpkgs/{rev}";
    kix.url = "git+file://{}?dir=kix";
  }};
  outputs =
    inputs:
    inputs.kix.lib.mkFlake {{
      inherit inputs;
      systems = [ "x86_64-linux" ];
      clusters = {{
        sweep-a = ./a.nix;
        sweep-b = ./b.nix;
      }};
    }};
}}
"#,
            repo_root().display()
        );
        let t = TwoClusters { dir };
        t.write("flake.nix", &flake);
        t.write("shared-role.nix", SHARED_ROLE_NIX);
        t.write_cluster("a", "hello from sweep-a", true);
        t.write_cluster("b", "hello from sweep-b", true);
        git(t.path(), &["init", "-q"]);
        git(t.path(), &["add", "-A"]);
        t
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn write(&self, name: &str, text: &str) {
        std::fs::write(self.path().join(name), text).unwrap();
        if self.path().join(".git").exists() {
            git(self.path(), &["add", "-A"]);
        }
    }

    fn write_cluster(&self, id: &str, message: &str, shared: bool) {
        let shared = if shared {
            "namespaces.shared = { };\n      instances.shared.shared-role.package = import ./shared-role.nix;"
        } else {
            ""
        };
        let text = format!(
            r#"{{ kix, packages }}:
kix.buildCluster {{
  name = "sweep-{id}";
  modules = [
    kix.flavors.kind
    {{
      namespaces.echo-{id} = {{ }};
      {shared}
      instances.echo-{id}.echo-server = {{
        package = packages.echo-server;
        config.message = "{message}";
      }};
    }}
  ];
}}
"#
        );
        self.write(&format!("{id}.nix"), &text);
    }

    fn kix(&self, kube_ctx: &str, args: &[&str]) -> (bool, String) {
        let out = assert_cmd::Command::cargo_bin("kix")
            .unwrap()
            .env("NO_COLOR", "true")
            .arg("--flake")
            .arg(self.path())
            .args(["--context", kube_ctx])
            .args(args)
            .output()
            .expect("kix should run");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        eprintln!("$ kix {}\n{text}", args.join(" "));
        (out.status.success(), text)
    }
}

fn git(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .is_ok_and(|o| o.status.success());
    assert!(ok, "git {args:?} failed");
}

/// Every object of Kix cluster `sweep-b` that must survive `sweep-a`'s
/// commands.
fn assert_b_intact(kube_ctx: &str) {
    for (kind, ns, name) in [
        ("deployment", "echo-b", "echo-server"),
        ("service", "echo-b", "echo-server"),
        ("configmap", "echo-b", "echo-server"),
        ("clusterrole", "", "sweep-test-reader"),
        ("configmap", "shared", "sweep-test-shared"),
    ] {
        let mut args = vec!["get", kind, name, "-o", "name"];
        if !ns.is_empty() {
            args.extend(["-n", ns]);
        }
        let out = kubectl(kube_ctx, &args);
        assert!(
            out.status.success(),
            "{kind}/{name} of sweep-b is gone: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

/// Two Kix clusters deploy into one kind cluster, sharing a ClusterRole and
/// a ConfigMap. Every command run for `sweep-a` leaves
/// `sweep-b`'s objects alone, and a prune by `sweep-a` keeps what `sweep-b`
/// still deploys.
///
/// The kind cluster is `$KIX_KIND_CLUSTER` (default `kix-sweep-scope`); the
/// test creates and deletes it.
#[test]
#[ignore] // Run explicitly: cargo test --test kind_integration_test -- --ignored
fn two_kix_clusters_share_one_kind_cluster() {
    if !has_kind() || !has_kubectl() {
        eprintln!("skipping: kind or kubectl not available");
        return;
    }
    let kind_cluster =
        std::env::var("KIX_KIND_CLUSTER").unwrap_or_else(|_| "kix-sweep-scope".into());
    let ctx = format!("kind-{kind_cluster}");
    kind_delete(&kind_cluster);
    clear_activation_cache("sweep-a");
    clear_activation_cache("sweep-b");
    assert!(kind_create(&kind_cluster), "failed to create kind cluster");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            kind_delete(&self.0);
        }
    }
    let _cleanup = Cleanup(kind_cluster.clone());

    let flake = TwoClusters::new();
    assert!(flake.kix(&ctx, &["deploy", "sweep-a", "--yes"]).0);
    assert!(flake.kix(&ctx, &["deploy", "sweep-b", "--yes"]).0);
    assert_b_intact(&ctx);

    // 1. `kix diff sweep-a` reports no change: sweep-b's objects are not
    //    removals.
    let (ok, out) = flake.kix(&ctx, &["diff", "sweep-a"]);
    assert!(ok, "diff sweep-a should report no change:\n{out}");
    assert!(out.contains("belong to Kix cluster sweep-b"), "{out}");

    // 2. `kix status sweep-a` and `kix snapshot save sweep-a` contain none
    //    of sweep-b's objects.
    let (ok, out) = flake.kix(&ctx, &["status", "sweep-a"]);
    assert!(ok && !out.contains("echo-b"), "{out}");
    let snap = tempfile::tempdir().unwrap();
    let snap_dir = snap.path().join("a");
    let (ok, _) = flake.kix(
        &ctx,
        &["snapshot", "save", "sweep-a", snap_dir.to_str().unwrap()],
    );
    assert!(ok);
    assert!(!snap_dir.join("echo-b").exists());
    assert!(snap_dir.join("echo-a").exists());

    // 3. The rebuild-from-live path: the Active record's build is not in
    //    the store, so deploy reads the previous state from live objects.
    let records = format!("activations.{}", keys::DOMAIN);
    let selector = format!("{}=sweep-a", keys::CLUSTER_LABEL);
    let record = kubectl_stdout(
        &ctx,
        &[
            "get",
            &records,
            "-l",
            &selector,
            "-o",
            "jsonpath={range .items[?(@.status.phase==\"Active\")]}{.metadata.name}{end}",
        ],
    );
    let gone = format!(
        "{}=/nix/store/00000000000000000000000000000000-gone",
        keys::BUILT_VIA
    );
    let annotate = kubectl(
        &ctx,
        &["annotate", &records, record.trim(), &gone, "--overwrite"],
    );
    assert!(annotate.status.success());
    clear_activation_cache("sweep-a");
    flake.write_cluster("a", "hello again from sweep-a", true);
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--prune", "--yes"]);
    assert!(ok, "{out}");
    assert!(out.contains("Reconstructing previous state"), "{out}");
    assert_b_intact(&ctx);

    // 4. `kix gc sweep-a --hard --yes` deletes nothing of sweep-b's.
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--hard", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);

    // 5. sweep-a drops the shared package; its prune keeps what sweep-b
    //    still deploys.
    flake.write_cluster("a", "hello again from sweep-a", false);
    let (ok, out) = flake.kix(&ctx, &["deploy", "sweep-a", "--prune", "--yes"]);
    assert!(ok, "{out}");
    assert!(
        out.contains("kept ClusterRole/sweep-test-reader")
            && out.contains("still deployed by Kix cluster sweep-b"),
        "{out}"
    );
    assert_b_intact(&ctx);
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--hard", "--yes"]);
    assert!(ok, "{out}");
    assert_b_intact(&ctx);

    // `--include-unattributed` needs `--hard`.
    let (ok, out) = flake.kix(&ctx, &["gc", "sweep-a", "--include-unattributed"]);
    assert!(!ok && out.contains("--hard"), "{out}");
}
