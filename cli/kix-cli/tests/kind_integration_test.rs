//! Integration test against a real kind cluster.
//!
//! Requires: `kind` and `kubectl` on PATH, Nix FFI available.
//! Creates a temporary kind cluster, deploys the `kind` cluster definition
//! (echo-server in its own namespace — no conflicts with kind's built-ins),
//! verifies deploy, local DAG diff, soft GC, and hard GC.
//!
//! Run with: cargo test --test kind_integration_test -- --ignored
//! (ignored by default because it requires kind + is slow)

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
            "kix.dev/identity-hash=fake00000000orphan000000000000",
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
