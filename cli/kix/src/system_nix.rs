//! Check the machine's Nix before the `nix` builder uses it.
//!
//! The `nix` builder runs the `nix` on `PATH` with the machine's settings
//! (see [`crate::runtime::NixRunner::System`]). Kix's library uses pipe
//! operators, which need Nix 2.24 or later, and Lix parses them differently,
//! so Kix checks `nix --version` once per run before it starts any other Nix
//! program.

use std::process::Command;
use std::sync::OnceLock;

/// The oldest Nix release the `nix` builder supports, as (major, minor).
pub const MIN_VERSION: (u64, u64) = (2, 24);

/// What `nix --version` says about the machine's Nix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NixKind {
    /// Nix, with its (major, minor) version.
    Nix { major: u64, minor: u64 },
    /// Lix, which names itself in the version line.
    Lix,
    /// A version line Kix cannot read.
    Unknown,
}

/// Read the first line of `nix --version` output, such as
/// `nix (Nix) 2.31.2`, `nix (Determinate Nix 3.8.2) 2.30.1`, or
/// `nix (Lix, like Nix) 2.91.1`.
pub fn parse_version(line: &str) -> NixKind {
    if line.contains("Lix") {
        return NixKind::Lix;
    }
    let Some(version) = line.split_whitespace().last() else {
        return NixKind::Unknown;
    };
    let mut parts = version.split('.').map(|p| {
        p.chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse::<u64>()
    });
    match (parts.next(), parts.next()) {
        (Some(Ok(major)), Some(Ok(minor))) => NixKind::Nix { major, minor },
        _ => NixKind::Unknown,
    }
}

/// Why the `nix` builder cannot use the machine's Nix.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SystemNixError {
    #[error(
        "this project uses the machine's Nix (builder = \"nix\" in kix.toml), but Kix found no `nix` program on PATH. Install Nix {}.{} or later, or remove builder = \"nix\" from kix.toml to build with Kix's own Nix",
        MIN_VERSION.0,
        MIN_VERSION.1
    )]
    NotInstalled,

    #[error(
        "this project uses the machine's Nix (builder = \"nix\" in kix.toml), but `nix --version` failed: {0}"
    )]
    Failed(String),

    #[error(
        "this project uses the machine's Nix (builder = \"nix\" in kix.toml), which must be Nix {}.{} or later, and `nix --version` reports {version}. Upgrade Nix",
        MIN_VERSION.0,
        MIN_VERSION.1
    )]
    TooOld { version: String },

    #[error(
        "this project uses the machine's Nix (builder = \"nix\" in kix.toml), and `nix --version` reports {version}. The nix builder does not support Lix. Install Nix {}.{} or later, or remove builder = \"nix\" from kix.toml to build with Kix's own Nix",
        MIN_VERSION.0,
        MIN_VERSION.1
    )]
    Lix { version: String },
}

/// Check the version line of the machine's Nix.
pub fn check_version(line: &str) -> Result<(), SystemNixError> {
    match parse_version(line) {
        NixKind::Lix => Err(SystemNixError::Lix {
            version: line.to_string(),
        }),
        NixKind::Nix { major, minor } if (major, minor) < MIN_VERSION => {
            Err(SystemNixError::TooOld {
                version: line.to_string(),
            })
        }
        NixKind::Nix { .. } => Ok(()),
        NixKind::Unknown => {
            tracing::warn!(
                version = line,
                "Kix could not read the version of the machine's Nix, so it does not check that it is Nix 2.24 or later"
            );
            Ok(())
        }
    }
}

/// Return the first line of `nix --version` from the `nix` on `PATH`.
pub fn version_line() -> Result<String, SystemNixError> {
    let out = Command::new("nix")
        .arg("--version")
        .output()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => SystemNixError::NotInstalled,
            _ => SystemNixError::Failed(e.to_string()),
        })?;
    if !out.status.success() {
        return Err(SystemNixError::Failed(format!(
            "{}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .unwrap_or_default()
        .trim()
        .to_string())
}

/// Check the machine's Nix once per run, and return the same result on
/// every later call.
pub fn check_once() -> Result<(), SystemNixError> {
    static CHECKED: OnceLock<Result<(), SystemNixError>> = OnceLock::new();
    CHECKED
        .get_or_init(|| check_version(&version_line()?))
        .clone()
}

/// Return whether the machine's Nix allows import from derivation, which the
/// `nix` builder needs to render Helm charts, or `None` when Kix cannot tell.
pub fn import_from_derivation_allowed() -> Option<bool> {
    let out = nix_stdout(&["config", "show", "allow-import-from-derivation"])?;
    match out.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// Return whether the machine's Nix store trusts this user, as
/// `nix store info --json` reports it, or `None` when it does not say.
pub fn store_trusted() -> Option<bool> {
    let out = nix_stdout(&["store", "info", "--json"])?;
    serde_json::from_str::<serde_json::Value>(&out)
        .ok()?
        .get("trusted")?
        .as_bool()
}

fn nix_stdout(args: &[&str]) -> Option<String> {
    let out = Command::new("nix")
        .args(["--extra-experimental-features", "nix-command"])
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_lines_parse() {
        assert_eq!(
            parse_version("nix (Nix) 2.31.2"),
            NixKind::Nix {
                major: 2,
                minor: 31
            }
        );
        assert_eq!(
            parse_version("nix (Determinate Nix 3.8.2) 2.30.1"),
            NixKind::Nix {
                major: 2,
                minor: 30
            }
        );
        assert_eq!(
            parse_version("nix (Nix) 2.24.0pre20240501_dirty"),
            NixKind::Nix {
                major: 2,
                minor: 24
            }
        );
        assert_eq!(parse_version("nix (Lix, like Nix) 2.91.1"), NixKind::Lix);
        assert_eq!(parse_version(""), NixKind::Unknown);
        assert_eq!(parse_version("nix (Nix) unknown"), NixKind::Unknown);
    }

    #[test]
    fn old_nix_and_lix_are_refused() {
        check_version("nix (Nix) 2.24.0").unwrap();
        check_version("nix (Nix) 3.0.1").unwrap();

        let err = check_version("nix (Nix) 2.18.1").unwrap_err().to_string();
        assert!(err.contains("must be Nix 2.24 or later"), "{err}");
        assert!(err.contains("reports nix (Nix) 2.18.1"), "{err}");

        let err = check_version("nix (Lix, like Nix) 2.91.1")
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("The nix builder does not support Lix"),
            "{err}"
        );

        check_version("something else").unwrap();
    }

    #[test]
    fn a_missing_nix_names_the_fix() {
        let err = SystemNixError::NotInstalled.to_string();
        assert!(err.contains("no `nix` program on PATH"), "{err}");
        assert!(err.contains("Install Nix 2.24 or later"), "{err}");
    }
}
