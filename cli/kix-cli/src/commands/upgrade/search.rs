//! Find the lines in a project that name a command or flag a change record
//! says was removed or changed.

use std::path::Path;

use super::state::CliHit;

/// Files larger than this are not searched.
const MAX_BYTES: u64 = 1024 * 1024;

/// Return whether the file at `rel`, relative to the project, is skipped:
/// the lock file and the files that describe Kix's own changes.
fn skipped(rel: &str) -> bool {
    rel == "flake.lock"
        || rel == "CHANGELOG.md"
        || rel.starts_with("changes/")
        || rel == super::state::FILE
}

/// Return the files git tracks under `dir`, relative to it, or `None` when
/// `dir` is not in a git repository.
pub fn tracked(dir: &Path) -> Option<Vec<String>> {
    let out = std::process::Command::new("git")
        .args(["ls-files", "-z"])
        .current_dir(dir)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        out.stdout
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect(),
    )
}

/// Search `files` under `dir` for each of `needles`.
pub fn search(dir: &Path, files: &[String], needles: &[String]) -> Vec<CliHit> {
    let mut hits = Vec::new();
    if needles.is_empty() {
        return hits;
    }
    for rel in files {
        if skipped(rel) {
            continue;
        }
        let path = dir.join(rel);
        if std::fs::metadata(&path).map_or(true, |m| !m.is_file() || m.len() > MAX_BYTES) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for (n, line) in text.lines().enumerate() {
            for needle in needles {
                if line.contains(needle.as_str()) {
                    hits.push(CliHit {
                        text: needle.clone(),
                        file: rel.clone(),
                        line: n + 1,
                    });
                }
            }
        }
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_finds_lines_and_skips_kix_files() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        std::fs::create_dir_all(d.join("changes")).unwrap();
        std::fs::create_dir_all(d.join("ci")).unwrap();
        std::fs::write(
            d.join("ci/deploy.sh"),
            "set -e\nkix deploy shop --old-flag\n",
        )
        .unwrap();
        std::fs::write(d.join("CHANGELOG.md"), "--old-flag\n").unwrap();
        std::fs::write(d.join("changes/x.md"), "--old-flag\n").unwrap();
        std::fs::write(d.join("flake.lock"), "--old-flag\n").unwrap();
        std::fs::write(d.join("big.txt"), "--old-flag\n".repeat(200_000)).unwrap();
        let files: Vec<String> = [
            "ci/deploy.sh",
            "CHANGELOG.md",
            "changes/x.md",
            "flake.lock",
            "big.txt",
            "missing.txt",
        ]
        .map(String::from)
        .into();
        let hits = search(d, &files, &["--old-flag".to_string()]);
        assert_eq!(
            hits,
            [CliHit {
                text: "--old-flag".into(),
                file: "ci/deploy.sh".into(),
                line: 2
            }]
        );
        assert!(search(d, &files, &[]).is_empty());
    }
}
