//! `kix::eval::eval_cluster_name` against real flakes. Each test runs
//! `nix eval`, so they live here rather than among the unit tests.

fn repo_root() -> String {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root");
    root.display().to_string()
}

/// The repository flake maps attribute `minimal` to
/// `clusters/test-minimal.nix`, whose `name` is `test-minimal`. Records carry
/// that name, so it is what the lookups get.
#[test]
fn a_flake_attribute_resolves_to_the_cluster_name() {
    assert_eq!(
        kix::eval::eval_cluster_name(&repo_root(), "minimal", &[]).unwrap(),
        Some("test-minimal".to_string())
    );
}

/// An argument the flake does not define is already a cluster name, as it
/// is for a cluster deployed from another flake.
#[test]
fn a_name_the_flake_does_not_define_has_no_evaluated_name() {
    assert_eq!(
        kix::eval::eval_cluster_name(&repo_root(), "test-minimal", &[]).unwrap(),
        None
    );
}

/// A flake that defines no `kixClusters` has no name to give, and that is
/// not an error.
#[test]
fn a_flake_without_kix_clusters_has_no_name() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("flake.nix"), "{ outputs = _: { }; }").unwrap();
    assert_eq!(
        kix::eval::eval_cluster_name(&dir.path().display().to_string(), "harbor", &[]).unwrap(),
        None
    );
}

/// A remote flake reference is passed to `nix eval` as part of the
/// installable, not used as a working directory.
#[test]
fn a_remote_flake_reference_is_an_installable() {
    let cmd = kix::eval::cluster_name_command("github:org/repo", "harbor", &[]).unwrap();
    assert_eq!(cmd.get_current_dir(), None);
    let args: Vec<String> = cmd
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    assert!(
        args[1].starts_with("github:org/repo#legacyPackages."),
        "{args:?}"
    );
}
