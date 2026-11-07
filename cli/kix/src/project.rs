//! Read a project's `kix.toml`, which chooses how Kix builds the project.
//!
//! The file sits beside `flake.nix` in the directory `--flake` names. It is
//! optional, and today it holds one optional key:
//!
//! ```toml
//! builder = "kix"   # "kix" (the default), "nix", or "remote"
//! ```
//!
//! The builder belongs to the project, so everyone who builds it, and its CI,
//! uses the same one. No flag or user setting changes it. Kix's own tests
//! override it with [`TEST_BUILDER_VAR`].

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// The name of the project file.
pub const FILE: &str = "kix.toml";

/// The environment variable that overrides the builder in `kix.toml`.
///
/// It exists for Kix's own tests only, which run the same test projects
/// under each builder. Do not document it for users.
pub const TEST_BUILDER_VAR: &str = "KIX_TEST_BUILDER";

/// The keys this version of Kix reads from `kix.toml`.
const KNOWN_KEYS: &[&str] = &["builder"];

/// How Kix builds a project.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BuilderKind {
    /// Kix's own Nix and its own store.
    #[default]
    Kix,
    /// The Nix installed on the machine, with its settings and store.
    Nix,
    /// A build service that Kix reaches over the network.
    Remote,
}

impl BuilderKind {
    /// Every builder, in the order messages list them.
    pub const ALL: [BuilderKind; 3] = [BuilderKind::Kix, BuilderKind::Nix, BuilderKind::Remote];

    /// Return the value that selects this builder in `kix.toml`.
    pub fn name(self) -> &'static str {
        match self {
            BuilderKind::Kix => "kix",
            BuilderKind::Nix => "nix",
            BuilderKind::Remote => "remote",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|b| b.name() == value)
    }
}

impl std::fmt::Display for BuilderKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Where the builder choice came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuilderSource {
    /// The `builder` key of this `kix.toml`.
    File(PathBuf),
    /// Nothing chose a builder, so Kix uses the default.
    Default,
    /// [`TEST_BUILDER_VAR`] overrides the project.
    TestOverride,
}

impl std::fmt::Display for BuilderSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BuilderSource::File(path) => write!(f, "{}", path.display()),
            BuilderSource::Default => f.write_str("the default, since no kix.toml sets a builder"),
            BuilderSource::TestOverride => write!(f, "{TEST_BUILDER_VAR}"),
        }
    }
}

/// The settings a project's `kix.toml` makes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectConfig {
    pub builder: BuilderKind,
    pub builder_source: BuilderSource,
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            builder: BuilderKind::Kix,
            builder_source: BuilderSource::Default,
        }
    }
}

/// Why Kix cannot use a project's settings.
#[derive(Debug, thiserror::Error)]
pub enum ProjectError {
    #[error("could not read {}: {source}", path.display())]
    Unreadable {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("{} is not valid TOML: line {line}: {message}", path.display())]
    Syntax {
        path: PathBuf,
        line: usize,
        message: String,
    },

    #[error(
        "{} has a setting this version of Kix does not know: `{key}`. Kix {} knows these settings: {}. Check the spelling, or upgrade Kix if the project needs a newer version",
        path.display(),
        crate::VERSION,
        KNOWN_KEYS.join(", ")
    )]
    UnknownKey { path: PathBuf, key: String },

    #[error(
        "{origin} sets builder = {value}, which this version of Kix does not know. Kix {} knows these builders: {}. Check the spelling, or upgrade Kix if the project needs a newer version",
        crate::VERSION,
        builder_names()
    )]
    UnknownBuilder {
        origin: BuilderSource,
        value: String,
    },

    #[error(
        "{origin} sets builder = \"remote\", but this version of Kix cannot use a remote builder. Set builder = \"kix\", or remove the setting"
    )]
    RemoteUnsupported { origin: BuilderSource },
}

fn builder_names() -> String {
    BuilderKind::ALL.map(BuilderKind::name).join(", ")
}

impl ProjectConfig {
    /// Read the settings of the project in `flake_dir`, apply
    /// [`TEST_BUILDER_VAR`], and check that this version of Kix can use the builder.
    ///
    /// `None` means there is no local project directory, such as a remote
    /// flake reference, and the project gets the default settings.
    pub fn load(flake_dir: Option<&Path>) -> Result<Self, ProjectError> {
        let config = Self::read_with_env(flake_dir)?;
        config.check_supported()?;
        Ok(config)
    }

    /// Read the settings of the project in `flake_dir` and apply
    /// [`TEST_BUILDER_VAR`], without checking that this version of Kix can use the
    /// builder.
    pub fn read_with_env(flake_dir: Option<&Path>) -> Result<Self, ProjectError> {
        let test_builder = std::env::var_os(TEST_BUILDER_VAR).filter(|v| !v.is_empty());
        Self::read(flake_dir, test_builder.as_deref())
    }

    /// Read the settings of the project in `flake_dir` without checking that
    /// this version of Kix can use the builder. `test_builder` is the value of
    /// [`TEST_BUILDER_VAR`], and replaces the file when set.
    pub fn read(
        flake_dir: Option<&Path>,
        test_builder: Option<&OsStr>,
    ) -> Result<Self, ProjectError> {
        if let Some(value) = test_builder {
            let value = value.to_string_lossy();
            return Ok(Self {
                builder: parse_builder(&value, BuilderSource::TestOverride)?,
                builder_source: BuilderSource::TestOverride,
            });
        }
        let Some(dir) = flake_dir else {
            return Ok(Self::default());
        };
        let path = dir.join(FILE);
        match std::fs::read_to_string(&path) {
            Ok(text) => Self::parse(&path, &text),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(source) => Err(ProjectError::Unreadable { path, source }),
        }
    }

    /// Parse the text of the `kix.toml` at `path`.
    fn parse(path: &Path, text: &str) -> Result<Self, ProjectError> {
        let table: toml::Table = toml::from_str(text).map_err(|e| ProjectError::Syntax {
            path: path.to_path_buf(),
            line: e
                .span()
                .map_or(1, |span| text[..span.start].matches('\n').count() + 1),
            message: e.message().to_string(),
        })?;
        if let Some(key) = table.keys().find(|k| !KNOWN_KEYS.contains(&k.as_str())) {
            return Err(ProjectError::UnknownKey {
                path: path.to_path_buf(),
                key: key.clone(),
            });
        }
        let Some(value) = table.get("builder") else {
            return Ok(Self::default());
        };
        let origin = BuilderSource::File(path.to_path_buf());
        let builder = match value.as_str() {
            Some(name) => parse_builder(name, origin.clone())?,
            None => {
                return Err(ProjectError::UnknownBuilder {
                    origin,
                    value: value.to_string(),
                });
            }
        };
        Ok(Self {
            builder,
            builder_source: origin,
        })
    }

    /// Fail when this version of Kix cannot build with the chosen builder.
    pub fn check_supported(&self) -> Result<(), ProjectError> {
        let origin = self.builder_source.clone();
        match self.builder {
            BuilderKind::Kix | BuilderKind::Nix => Ok(()),
            BuilderKind::Remote => Err(ProjectError::RemoteUnsupported { origin }),
        }
    }
}

/// Why the builder Kix read from `kix.toml` and the one the project's Kix
/// library read differ.
///
/// The library reads `kix.toml` through Nix, which sees only the files git
/// tracks, so the two can disagree.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProjectMismatch {
    #[error(
        "{origin} sets builder = \"nix\", but this project's Kix library is too old for the nix builder. Run `kix lib update` to move flake.lock to the Kix library {}",
        crate::VERSION
    )]
    LibraryTooOld { origin: BuilderSource },

    #[error(
        "kix.toml is not visible to Nix. Run `git add kix.toml`. Kix reads builder = \"nix\" from {origin}, but Nix leaves out files that git does not track, so the project's Kix library uses builder = \"kix\""
    )]
    NotVisible { origin: BuilderSource },

    #[error(
        "Kix and the project's Kix library disagree about the builder. Kix uses builder = \"{cli}\" ({origin}), and the library uses builder = \"{library}\". Check that git tracks kix.toml, and that flake.nix passes its `self` input to kix.lib.mkFlake"
    )]
    Disagree {
        origin: BuilderSource,
        cli: BuilderKind,
        library: String,
    },
}

/// Check that the builder Kix uses, which `origin` chose, agrees with
/// `library`, the builder the project's Kix library read from `kix.toml`.
/// `library` is `None` when the library is older than the setting.
///
/// The test override replaces the file on purpose, so it is never compared.
pub fn check_agreement(
    cli: BuilderKind,
    origin: &BuilderSource,
    library: Option<&str>,
) -> Result<(), ProjectMismatch> {
    if *origin == BuilderSource::TestOverride {
        return Ok(());
    }
    let origin = origin.clone();
    match library {
        None if cli == BuilderKind::Nix => Err(ProjectMismatch::LibraryTooOld { origin }),
        None => Ok(()),
        Some(library) if library == cli.name() => Ok(()),
        Some("kix") if cli == BuilderKind::Nix && matches!(origin, BuilderSource::File(_)) => {
            Err(ProjectMismatch::NotVisible { origin })
        }
        Some(library) => Err(ProjectMismatch::Disagree {
            origin,
            cli,
            library: library.to_string(),
        }),
    }
}

fn parse_builder(value: &str, origin: BuilderSource) -> Result<BuilderKind, ProjectError> {
    BuilderKind::parse(value).ok_or_else(|| ProjectError::UnknownBuilder {
        origin,
        value: format!("{value:?}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(text: Option<&str>) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        if let Some(text) = text {
            std::fs::write(dir.path().join(FILE), text).unwrap();
        }
        dir
    }

    fn read(text: Option<&str>) -> Result<ProjectConfig, ProjectError> {
        let dir = project(text);
        ProjectConfig::read(Some(dir.path()), None)
    }

    #[test]
    fn without_a_file_or_a_key_the_builder_is_kix() {
        assert_eq!(read(None).unwrap(), ProjectConfig::default());
        assert_eq!(read(Some("")).unwrap(), ProjectConfig::default());
        assert_eq!(
            read(Some("# nothing set\n")).unwrap(),
            ProjectConfig::default()
        );
        assert_eq!(
            ProjectConfig::read(None, None).unwrap(),
            ProjectConfig::default()
        );
        assert_eq!(
            ProjectConfig::read(Some(Path::new("/nonexistent/project")), None).unwrap(),
            ProjectConfig::default()
        );
    }

    #[test]
    fn each_builder_parses() {
        for builder in BuilderKind::ALL {
            let dir = project(Some(&format!("builder = \"{builder}\"\n")));
            let config = ProjectConfig::read(Some(dir.path()), None).unwrap();
            assert_eq!(config.builder, builder);
            assert_eq!(
                config.builder_source,
                BuilderSource::File(dir.path().join(FILE))
            );
        }
    }

    #[test]
    fn an_unknown_key_names_the_known_ones() {
        let err = read(Some("builder = \"kix\"\nbuidler = \"nix\"\n"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("`buidler`"), "{err}");
        assert!(err.contains("knows these settings: builder"), "{err}");
        assert!(err.contains("upgrade Kix"), "{err}");

        let err = read(Some("[remote]\nurl = \"x\"\n"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("`remote`"), "{err}");
    }

    #[test]
    fn an_unknown_builder_names_the_known_ones() {
        let err = read(Some("builder = \"nixos\"\n")).unwrap_err().to_string();
        assert!(err.contains("builder = \"nixos\""), "{err}");
        assert!(err.contains("kix, nix, remote"), "{err}");
        assert!(err.contains("Check the spelling"), "{err}");
        assert!(err.contains("kix.toml"), "{err}");

        let err = read(Some("builder = 3\n")).unwrap_err().to_string();
        assert!(err.contains("builder = 3"), "{err}");
    }

    #[test]
    fn bad_toml_names_the_file() {
        let err = read(Some("# a comment\nbuilder = \n")).unwrap_err();
        assert!(matches!(err, ProjectError::Syntax { line: 2, .. }), "{err}");
        assert!(
            err.to_string()
                .contains("kix.toml is not valid TOML: line 2"),
            "{err}"
        );
    }

    #[test]
    fn remote_is_refused() {
        let config = read(Some("builder = \"remote\"\n")).unwrap();
        let err = config.check_supported().unwrap_err().to_string();
        assert!(err.contains("cannot use a remote builder"), "{err}");
        assert!(err.contains("kix.toml sets builder"), "{err}");

        for builder in ["kix", "nix"] {
            read(Some(&format!("builder = \"{builder}\"\n")))
                .unwrap()
                .check_supported()
                .unwrap();
        }
    }

    #[test]
    fn the_library_must_read_the_same_builder() {
        let file = BuilderSource::File(PathBuf::from("/p/kix.toml"));
        check_agreement(BuilderKind::Nix, &file, Some("nix")).unwrap();
        check_agreement(BuilderKind::Kix, &BuilderSource::Default, Some("kix")).unwrap();
        // An older library has no setting, which only the nix builder needs.
        check_agreement(BuilderKind::Kix, &BuilderSource::Default, None).unwrap();

        let err = check_agreement(BuilderKind::Nix, &file, None)
            .unwrap_err()
            .to_string();
        assert!(err.contains("too old for the nix builder"), "{err}");
        assert!(err.contains("kix lib update"), "{err}");

        let err = check_agreement(BuilderKind::Nix, &file, Some("kix"))
            .unwrap_err()
            .to_string();
        assert!(
            err.starts_with("kix.toml is not visible to Nix. Run `git add kix.toml`."),
            "{err}"
        );

        let err = check_agreement(BuilderKind::Kix, &BuilderSource::Default, Some("nix"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("Kix uses builder = \"kix\""), "{err}");
        assert!(err.contains("the library uses builder = \"nix\""), "{err}");

        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, Some("kix")).unwrap();
        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, None).unwrap();
    }

    #[test]
    fn the_test_variable_overrides_the_file() {
        let dir = project(Some("builder = \"kix\"\n"));
        let config = ProjectConfig::read(Some(dir.path()), Some(OsStr::new("nix"))).unwrap();
        assert_eq!(config.builder, BuilderKind::Nix);
        assert_eq!(config.builder_source, BuilderSource::TestOverride);
        let config = ProjectConfig::read(Some(dir.path()), Some(OsStr::new("remote"))).unwrap();
        let err = config.check_supported().unwrap_err().to_string();
        assert!(err.starts_with("KIX_TEST_BUILDER sets builder"), "{err}");

        let config = ProjectConfig::read(None, Some(OsStr::new("kix"))).unwrap();
        assert_eq!(config.builder, BuilderKind::Kix);

        let err = ProjectConfig::read(Some(dir.path()), Some(OsStr::new("bogus")))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("KIX_TEST_BUILDER sets builder = \"bogus\""),
            "{err}"
        );
    }
}
