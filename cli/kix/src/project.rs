//! Read a project's `kix.toml`, which chooses how Kix builds the project and
//! which version of Kix builds it.
//!
//! The file sits beside `flake.nix` in the directory `--flake` names. It is
//! optional, and so is each of its keys:
//!
//! ```toml
//! builder = "kix"   # "kix" (the default), "nix", or "remote"
//! kix = "0.8"       # a minor such as "0.8", or an exact version such as "0.8.3"
//! ```
//!
//! Both belong to the project, so everyone who builds it, and its CI, uses
//! the same builder and a matching Kix. No flag or user setting changes them.
//! Kix's own tests override the builder with [`TEST_BUILDER_VAR`]. Kix reads
//! `kix` before it parses its arguments and runs the version the project
//! names (`select` in the `kix` binary).

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::version::policy::{self, Requirement};

/// The name of the project file.
pub const FILE: &str = "kix.toml";

/// The environment variable that overrides the builder in `kix.toml`.
///
/// It exists for Kix's own tests only, which run the same test projects
/// under each builder. Do not document it for users.
pub const TEST_BUILDER_VAR: &str = "KIX_TEST_BUILDER";

/// The keys this version of Kix reads from `kix.toml`.
const KNOWN_KEYS: &[&str] = &["builder", "kix"];

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
    /// The Kix the project needs, from the `kix` key.
    pub kix: Option<Requirement>,
    /// The `kix.toml` that set [`Self::kix`].
    pub kix_source: Option<PathBuf>,
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            builder: BuilderKind::Kix,
            builder_source: BuilderSource::Default,
            kix: None,
            kix_source: None,
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
        "{} has an unknown setting `{key}` (Kix {} supports: {}). Check the spelling, or upgrade Kix if the project needs a newer version",
        path.display(),
        crate::version::running().release(),
        KNOWN_KEYS.join(", ")
    )]
    UnknownKey { path: PathBuf, key: String },

    #[error(
        "{origin} sets builder = {value}, which is not a known builder (Kix {} supports: {}). Check the spelling, or upgrade Kix if the project needs a newer version",
        crate::version::running().release(),
        builder_names()
    )]
    UnknownBuilder {
        origin: BuilderSource,
        value: String,
    },

    #[error(
        "{origin} sets builder to {kind}. Write the builder's name in quotes, such as builder = \"kix\" (Kix {} supports: {})",
        crate::version::running().release(),
        builder_names()
    )]
    NotText { origin: BuilderSource, kind: String },

    #[error(
        "{origin} sets builder = \"remote\", but remote builders are not supported yet. Set builder = \"kix\", or remove the setting"
    )]
    RemoteUnsupported { origin: BuilderSource },

    #[error(
        "{} sets kix = {value}, which is not a Kix version. Write a minor such as kix = \"0.8\", or an exact version such as kix = \"0.8.3\"",
        path.display()
    )]
    BadKixVersion { path: PathBuf, value: String },

    #[error(
        "{} sets kix = \"{value}\", but Kix {value} and older cannot read this setting. Name Kix {}.{} or newer, or remove the line.",
        path.display(),
        policy::FIRST_SELECTING.0,
        policy::FIRST_SELECTING.1
    )]
    KixTooOld { path: PathBuf, value: String },

    #[error(
        "{} sets kix = {literal} as a number. Write it in quotes: kix = \"{literal}\"",
        path.display()
    )]
    KixNotQuoted { path: PathBuf, literal: String },
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
                ..Self::default()
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
        let kix = match table.get("kix") {
            None => None,
            Some(toml::Value::String(text)) => Some(parse_kix(path, text)?),
            Some(value @ (toml::Value::Integer(_) | toml::Value::Float(_))) => {
                let literal = kix_literal(text).unwrap_or_else(|| toml_text(value));
                if literal.parse::<Requirement>().is_ok() {
                    return Err(ProjectError::KixNotQuoted {
                        path: path.to_path_buf(),
                        literal,
                    });
                }
                return Err(ProjectError::BadKixVersion {
                    path: path.to_path_buf(),
                    value: literal,
                });
            }
            Some(value) => {
                return Err(ProjectError::BadKixVersion {
                    path: path.to_path_buf(),
                    value: toml_text(value),
                });
            }
        };
        let kix_source = kix.is_some().then(|| path.to_path_buf());
        let Some(value) = table.get("builder") else {
            return Ok(Self {
                kix,
                kix_source,
                ..Self::default()
            });
        };
        let origin = BuilderSource::File(path.to_path_buf());
        let builder = match value.as_str() {
            Some(name) => parse_builder(name, origin.clone())?,
            None => {
                return Err(ProjectError::NotText {
                    origin,
                    kind: match value {
                        toml::Value::Integer(_) | toml::Value::Float(_) => "a number",
                        toml::Value::Boolean(_) => "true or false",
                        toml::Value::Array(_) => "a list",
                        toml::Value::Table(_) => "a table",
                        _ => "a value that is not text",
                    }
                    .to_string(),
                });
            }
        };
        Ok(Self {
            builder,
            builder_source: origin,
            kix,
            kix_source,
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

/// The `kix` setting of a project's `kix.toml`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KixSetting {
    pub requirement: Requirement,
    /// The `kix.toml` that holds it.
    pub path: PathBuf,
}

/// Read only the `kix` setting of the `kix.toml` in `flake_dir`.
///
/// Kix reads this before it knows which version will run the command, and a
/// newer version may accept keys and values this one does not know. So this
/// ignores every other key, a missing or unreadable file, invalid TOML, and a
/// `kix` value that is not a version, and leaves those to
/// [`ProjectConfig::read`] in the Kix that runs. The one error is a version
/// older than [`policy::FIRST_SELECTING`], since no Kix it names could read
/// the file.
pub fn kix_setting(flake_dir: &Path) -> Result<Option<KixSetting>, ProjectError> {
    let path = flake_dir.join(FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(None);
    };
    let Ok(table) = toml::from_str::<toml::Table>(&text) else {
        return Ok(None);
    };
    let Some(Ok(requirement)) = table
        .get("kix")
        .and_then(toml::Value::as_str)
        .map(str::parse::<Requirement>)
    else {
        return Ok(None);
    };
    check_floor(&path, &requirement)?;
    Ok(Some(KixSetting { requirement, path }))
}

/// Parse the text of a `kix` value from the `kix.toml` at `path`.
fn parse_kix(path: &Path, text: &str) -> Result<Requirement, ProjectError> {
    let requirement = text
        .parse::<Requirement>()
        .map_err(|_| ProjectError::BadKixVersion {
            path: path.to_path_buf(),
            value: format!("{text:?}"),
        })?;
    check_floor(path, &requirement)?;
    Ok(requirement)
}

fn check_floor(path: &Path, requirement: &Requirement) -> Result<(), ProjectError> {
    if requirement.reads_kix_setting() {
        return Ok(());
    }
    Err(ProjectError::KixTooOld {
        path: path.to_path_buf(),
        value: requirement.to_string(),
    })
}

/// Return the `kix` value as `kix.toml` spells it, such as `0.10`, which a
/// TOML float would print as `0.1`.
fn kix_literal(text: &str) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Spans {
        kix: toml::Spanned<toml::Value>,
    }
    let spans: Spans = toml::from_str(text).ok()?;
    text.get(spans.kix.span()).map(|s| s.trim().to_string())
}

/// Why the builder Kix read from `kix.toml` and the one the project's Kix
/// library read differ.
///
/// The library reads `kix.toml` through Nix, which sees only the files git
/// tracks, so the two can disagree.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProjectMismatch {
    #[error(
        "{origin} sets builder = \"nix\", which this project's flake does not support. If flake.nix calls kixpkgs.lib.mkFlake, run `kix lib update` to update the Kix library in flake.lock. If flake.nix builds Kix outputs directly (for example with kixpkgs.lib.forPkgs), switch to kixpkgs.lib.mkFlake as shown in \"Use mkFlake in a consuming repo\" in the docs"
    )]
    NoBuilderSetting { origin: BuilderSource },

    #[error("{origin} is not tracked by Git, so Nix ignores it. Run `git add kix.toml`")]
    NotVisible { origin: BuilderSource },

    #[error(
        "the project's builder is `{cli}` ({origin}), but the flake evaluated with builder = \"{library}\". Check that Git tracks kix.toml, and that flake.nix passes its `self` input to kixpkgs.lib.mkFlake"
    )]
    Disagree {
        origin: BuilderSource,
        cli: BuilderKind,
        library: String,
    },
}

/// Check that the builder Kix uses, which `origin` chose, agrees with
/// `library`, the builder the project's Kix library read from `kix.toml`.
/// `library` is `None` when the flake publishes no builder setting: its
/// library is older than the setting, or the flake does not use `mkFlake`.
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
        None if cli == BuilderKind::Nix => Err(ProjectMismatch::NoBuilderSetting { origin }),
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

/// Return `value` the way it reads in `kix.toml`, short enough for a message.
fn toml_text(value: &toml::Value) -> String {
    match value {
        toml::Value::String(s) => format!("{s:?}"),
        toml::Value::Integer(n) => n.to_string(),
        toml::Value::Float(n) => n.to_string(),
        toml::Value::Boolean(b) => b.to_string(),
        toml::Value::Datetime(d) => d.to_string(),
        toml::Value::Array(_) => "[...]".to_string(),
        toml::Value::Table(_) => "{...}".to_string(),
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
        assert!(err.contains("supports: builder, kix"), "{err}");
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
        assert!(err.contains("sets builder to a number"), "{err}");
        assert!(err.contains("builder = \"kix\""), "{err}");
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
        assert!(
            err.contains("remote builders are not supported yet"),
            "{err}"
        );
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
        // A flake without the setting (an older library, or a flake that does
        // not use mkFlake) works only with the kix builder.
        check_agreement(BuilderKind::Kix, &BuilderSource::Default, None).unwrap();

        let err = check_agreement(BuilderKind::Nix, &file, None)
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("this project's flake does not support"),
            "{err}"
        );
        assert!(err.contains("kix lib update"), "{err}");
        assert!(err.contains("mkFlake"), "{err}");

        let err = check_agreement(BuilderKind::Nix, &file, Some("kix"))
            .unwrap_err()
            .to_string();
        assert!(
            err.starts_with(
                "/p/kix.toml is not tracked by Git, so Nix ignores it. Run `git add kix.toml`"
            ),
            "{err}"
        );

        let err = check_agreement(BuilderKind::Kix, &BuilderSource::Default, Some("nix"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("the project's builder is `kix`"), "{err}");
        assert!(
            err.contains("the flake evaluated with builder = \"nix\""),
            "{err}"
        );

        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, Some("kix")).unwrap();
        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, None).unwrap();
    }

    #[test]
    fn the_kix_key_takes_a_minor_or_an_exact_version() {
        let dir = project(Some("kix = \"0.8\"\n"));
        let config = ProjectConfig::read(Some(dir.path()), None).unwrap();
        assert_eq!(config.kix, Some(Requirement::Minor(0, 8)));
        assert_eq!(config.kix_source, Some(dir.path().join(FILE)));
        assert_eq!(config.builder_source, BuilderSource::Default);

        let config = read(Some("builder = \"nix\"\nkix = \"0.8.3\"\n")).unwrap();
        assert_eq!(
            config.kix,
            Some(Requirement::Exact("0.8.3".parse().unwrap()))
        );
        assert_eq!(config.builder, BuilderKind::Nix);

        assert_eq!(read(Some("builder = \"kix\"\n")).unwrap().kix, None);
    }

    #[test]
    fn a_kix_value_that_is_not_a_version_names_both_forms() {
        for (text, shown) in [
            ("kix = 8\n", "kix = 8,"),
            ("kix = \"0.8.x\"\n", "kix = \"0.8.x\","),
        ] {
            let err = read(Some(text)).unwrap_err();
            assert!(matches!(err, ProjectError::BadKixVersion { .. }), "{err}");
            let err = err.to_string();
            assert!(err.contains(shown), "{err}");
            assert!(
                err.ends_with(
                    "which is not a Kix version. Write a minor such as kix = \"0.8\", or an exact version such as kix = \"0.8.3\""
                ),
                "{err}"
            );
        }
    }

    #[test]
    fn a_kix_older_than_0_8_cannot_be_named() {
        for (text, value) in [("kix = \"0.7\"\n", "0.7"), ("kix = \"0.7.4\"\n", "0.7.4")] {
            let dir = project(Some(text));
            let expected = format!(
                "{} sets kix = \"{value}\", but Kix {value} and older cannot read this setting. Name Kix 0.8 or newer, or remove the line.",
                dir.path().join(FILE).display()
            );
            let err = ProjectConfig::read(Some(dir.path()), None).unwrap_err();
            assert_eq!(err.to_string(), expected);
            let err = kix_setting(dir.path()).unwrap_err();
            assert_eq!(err.to_string(), expected);
        }
    }

    #[test]
    fn an_unquoted_version_is_told_to_add_quotes() {
        for (text, literal) in [("kix = 0.8\n", "0.8"), ("kix = 0.10 # next\n", "0.10")] {
            let err = read(Some(text)).unwrap_err();
            assert!(matches!(err, ProjectError::KixNotQuoted { .. }), "{err}");
            assert!(
                err.to_string().ends_with(&format!(
                    "kix.toml sets kix = {literal} as a number. Write it in quotes: kix = \"{literal}\""
                )),
                "{err}"
            );
        }
    }

    #[test]
    fn selection_reads_only_the_kix_setting() {
        let dir = project(Some("kix = \"9.9\"\nfuture = 1\nbuilder = \"someday\"\n"));
        assert!(ProjectConfig::read(Some(dir.path()), None).is_err());
        assert_eq!(
            kix_setting(dir.path()).unwrap(),
            Some(KixSetting {
                requirement: Requirement::Minor(9, 9),
                path: dir.path().join(FILE),
            })
        );
        for text in [
            "kix = 0.8\n",
            "kix = \"0.8.x\"\n",
            "builder = \"kix\"\n",
            "kix = \n",
        ] {
            let dir = project(Some(text));
            assert_eq!(kix_setting(dir.path()).unwrap(), None, "{text}");
        }
        assert_eq!(
            kix_setting(Path::new("/nonexistent/project")).unwrap(),
            None
        );
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
