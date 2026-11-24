//! Read a project's `kix.toml`, which chooses how Kix builds the project.
//!
//! The file sits beside `flake.nix` in the directory `--flake` names. It is
//! optional, and so is each of its keys:
//!
//! ```toml
//! builder = "kix"   # "kix" (the default), "nix", or "remote"
//!
//! [upgrade]
//! min-age = "7d"    # `kix upgrade` picks only releases at least this old
//! ```
//!
//! The settings belong to the project, so everyone who builds it, and its
//! CI, uses the same builder. No flag or user setting changes them. Kix's
//! own tests override the builder with [`TEST_BUILDER_VAR`]. The version of
//! Kix a project uses comes from `flake.lock` (`crate::flake_lock`), and
//! Kix refuses a `kix` key here ([`KIX_SETTING_ID`]).

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
const KNOWN_KEYS: &[&str] = &["builder", "library", "upgrade", "versions"];

/// The id of the change record that moved the project's version of Kix from
/// `kix` in `kix.toml` to `flake.lock`.
pub const KIX_SETTING_ID: &str = "K4476";

/// The keys of the `[upgrade]` table.
const UPGRADE_KEYS: &[&str] = &["min-age"];

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
    /// `min-age` in the `[upgrade]` table, in days.
    pub upgrade_min_age: Option<u32>,
    /// Where the project takes its Kix library from, from the `library` key.
    pub library: Library,
}

/// Where a project takes its Kix library from (`library` in `kix.toml`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Library {
    /// `library = "input"`, the default: the flake input named `kix`, whose
    /// tag in `flake.lock` is the project's version of Kix.
    #[default]
    Input,
    /// `library = "self"`: the project's own flake provides the Kix library,
    /// so the project uses a development library.
    OwnFlake,
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            builder: BuilderKind::Kix,
            builder_source: BuilderSource::Default,
            upgrade_min_age: None,
            library: Library::Input,
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

    /// `version` is the value when it names a version, such as `"0.9"`.
    /// `old_input` is whether `flake.lock` names the Kix library input
    /// `kixpkgs`, so the same steps also rename it.
    #[error(
        "[{KIX_SETTING_ID}] {} sets kix = {value}, but Kix now takes this project's version from the Kix library tag in flake.lock. Run these steps with Kix 0.10 or later, because `kix upgrade` in Kix 0.9 writes the kix line back. Delete the kix line from kix.toml, {}then {}",
        path.display(),
        if *old_input { "rename the flake input kixpkgs to kix in flake.nix, " } else { "" },
        crate::flake_lock::pin_then_upgrade(version.as_deref())
    )]
    KixSettingRemoved {
        path: PathBuf,
        value: String,
        version: Option<String>,
        old_input: bool,
    },

    #[error(
        "{} sets library = {value}, which Kix does not know. Write library = \"input\" (the default: the flake input named kix holds the Kix library) or library = \"self\" (this flake provides the Kix library itself).",
        path.display()
    )]
    BadLibrary { path: PathBuf, value: String },

    #[error(
        "{} has a bad [upgrade] table: {problem}. Kix {} reads only min-age. Set min-age to a number of days in quotes, such as min-age = \"7d\", or remove [upgrade]",
        path.display(),
        crate::version::running().release()
    )]
    BadUpgrade { path: PathBuf, problem: String },

    #[error("{0}")]
    Versions(String),
}

/// Parse a minimum release age such as `7d` into days.
pub fn parse_min_age(text: &str) -> Option<u32> {
    text.trim().strip_suffix('d')?.parse().ok()
}

/// Read the `[upgrade]` table's `min-age`.
fn parse_upgrade(
    path: &Path,
    value: Option<&toml::Value>,
    held_back: bool,
) -> Result<Option<u32>, ProjectError> {
    let bad = |problem: String| ProjectError::BadUpgrade {
        path: path.to_path_buf(),
        problem,
    };
    let Some(value) = value else {
        return Ok(None);
    };
    let table = value
        .as_table()
        .ok_or_else(|| bad("upgrade must be a table".to_string()))?;
    if !held_back && let Some(key) = table.keys().find(|k| !UPGRADE_KEYS.contains(&k.as_str())) {
        return Err(bad(format!("`{key}` is not a setting")));
    }
    match table.get("min-age") {
        None => Ok(None),
        Some(toml::Value::String(text)) => parse_min_age(text)
            .map(Some)
            .ok_or_else(|| bad(format!("min-age = \"{text}\" is not a number of days"))),
        Some(other) => Err(bad(format!(
            "min-age = {} is not a number of days",
            toml_text(other)
        ))),
    }
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
            Ok(text) => Self::parse(&path, &text, crate::versions::held_back(dir)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(source) => Err(ProjectError::Unreadable { path, source }),
        }
    }

    /// Parse the text of the `kix.toml` at `path`. With `held_back`, this
    /// Kix is older than the newest one in the project, and skips the
    /// settings it does not know.
    fn parse(path: &Path, text: &str, held_back: bool) -> Result<Self, ProjectError> {
        let table: toml::Table = toml::from_str(text).map_err(|e| ProjectError::Syntax {
            path: path.to_path_buf(),
            line: e
                .span()
                .map_or(1, |span| text[..span.start].matches('\n').count() + 1),
            message: e.message().to_string(),
        })?;
        refuse_kix_setting(path, &table)?;
        if !held_back && let Some(key) = table.keys().find(|k| !KNOWN_KEYS.contains(&k.as_str())) {
            return Err(ProjectError::UnknownKey {
                path: path.to_path_buf(),
                key: key.clone(),
            });
        }
        let upgrade_min_age = parse_upgrade(path, table.get("upgrade"), held_back)?;
        let library = parse_library(path, table.get("library"))?;
        if let Some(versions) = table.get(crate::versions::TABLE) {
            let bad = |e: crate::versions::VersionsError| ProjectError::Versions(e.to_string());
            crate::versions::Versions::parse(versions, held_back).map_err(bad)?;
            if library == Library::OwnFlake {
                return Err(bad(crate::versions::VersionsError::OwnLibrary));
            }
        }
        let Some(value) = table.get("builder") else {
            return Ok(Self {
                upgrade_min_age,
                library,
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
            upgrade_min_age,
            library,
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

/// Refuse the `kix` key of the `kix.toml` at `path`, which named the
/// project's version of Kix before `flake.lock` did.
fn refuse_kix_setting(path: &Path, table: &toml::Table) -> Result<(), ProjectError> {
    let Some(value) = table.get("kix") else {
        return Ok(());
    };
    let version = value
        .as_str()
        .filter(|v| v.parse::<crate::version::policy::Requirement>().is_ok());
    Err(ProjectError::KixSettingRemoved {
        path: path.to_path_buf(),
        value: toml_text(value),
        version: version.map(str::to_string),
        old_input: path.parent().is_some_and(names_old_input),
    })
}

/// Return whether the `flake.lock` in `dir` names the Kix library input
/// `kixpkgs`. A missing or unreadable lock names no input.
fn names_old_input(dir: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(dir.join(crate::flake_lock::FILE)) else {
        return false;
    };
    let Ok(lock) = serde_json::from_str::<serde_json::Value>(&text) else {
        return false;
    };
    matches!(
        crate::flake_lock::kix_input(&lock),
        Err(crate::flake_lock::InputError::OldName { .. })
    )
}

/// Read `library` from a `kix.toml`. A missing key is [`Library::Input`].
fn parse_library(path: &Path, value: Option<&toml::Value>) -> Result<Library, ProjectError> {
    match value {
        None => Ok(Library::Input),
        Some(toml::Value::String(s)) if s == "input" => Ok(Library::Input),
        Some(toml::Value::String(s)) if s == "self" => Ok(Library::OwnFlake),
        Some(value) => Err(ProjectError::BadLibrary {
            path: path.to_path_buf(),
            value: toml_text(value),
        }),
    }
}

/// Return where the project in `flake_dir` takes its Kix library from, as
/// its `kix.toml` says.
///
/// Kix reads this before it knows which version runs the command, so a
/// missing or unreadable file and invalid TOML count as the default and are
/// left to [`ProjectConfig::read`]. An unknown `library` value is an error.
pub fn library_setting(flake_dir: &Path) -> Result<Library, ProjectError> {
    let path = flake_dir.join(FILE);
    let Some(table) = lenient_table(&path) else {
        return Ok(Library::Input);
    };
    parse_library(&path, table.get("library"))
}

/// Refuse a `kix` key in the `kix.toml` of `flake_dir` ([`KIX_SETTING_ID`]),
/// reading the file as leniently as [`library_setting`] does.
///
/// The key marks a project set up for Kix 0.9, and its error gives the steps
/// that also fix that project's `flake.lock`. So when Kix cannot tell a
/// project's version from `flake.lock`, it reports this error first.
pub fn kix_setting(flake_dir: &Path) -> Result<(), ProjectError> {
    let path = flake_dir.join(FILE);
    match lenient_table(&path) {
        Some(table) => refuse_kix_setting(&path, &table),
        None => Ok(()),
    }
}

/// Return the `kix.toml` at `path` as a table, or `None` when it is missing,
/// unreadable, or not valid TOML.
fn lenient_table(path: &Path) -> Option<toml::Table> {
    toml::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// Why the builder Kix read from `kix.toml` and the one the project's Kix
/// library read differ.
///
/// The library reads `kix.toml` through Nix, which sees only the files git
/// tracks, so the two can disagree.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProjectMismatch {
    #[error(
        "{origin} sets `builder = \"nix\"`, which this project's flake did not configure\n  \
         No project files or cluster resources were changed.\n\n  \
         Why:\n    \
         Either the Kix library pinned in `flake.lock` is older than the `builder` setting, or `flake.nix` builds Kix outputs directly instead of calling `kix.lib.mkFlake`.\n\n  \
         Next (choose one):\n    \
         - If `flake.nix` already calls `kix.lib.mkFlake`, move the Kix library in `flake.lock` to this version of Kix, then run the command again:\n        \
         kix upgrade --to {kix}\n    \
         - If `flake.nix` builds Kix outputs another way (for example with `kix.lib.forPkgs`), switch to `kix.lib.mkFlake` as shown in the `builder` section at https://kix.run/docs/reference/kix-toml/.",
        kix = crate::version::running().release()
    )]
    NoBuilderSetting { origin: BuilderSource },

    #[error("{origin} is not tracked by Git, so Nix ignores it. Run `git add kix.toml`")]
    NotVisible { origin: BuilderSource },

    #[error(
        "builder mismatch: Kix selected the `{cli}` builder ({origin}), while the Kix library evaluated with the `{library}` builder\n  \
         No project files or cluster resources were changed.\n\n  \
         Builder selected by Kix:         {cli} ({origin})\n  \
         Builder read by the Kix library: {library}\n\n  \
         Why:\n    \
         Kix reads `kix.toml` from the current local directory before starting, while the Kix library reads `kix.toml` from `inputs.self` in `kix.lib.mkFlake`.\n\n  \
         Next (choose one):\n    \
         - If you passed `--flake` with a remote flake whose `kix.toml` sets `builder = \"{library}\"`, clone that repository locally and run `kix` inside it.\n    \
         - Otherwise, check that `flake.nix` passes `inputs` to `kix.lib.mkFlake` (`kix.lib.mkFlake {{ inherit inputs; ... }}`)."
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
    fn the_upgrade_table_sets_a_minimum_age() {
        let config = read(Some("[upgrade]\nmin-age = \"7d\"\n")).unwrap();
        assert_eq!(config.upgrade_min_age, Some(7));
        assert_eq!(read(Some("[upgrade]\n")).unwrap().upgrade_min_age, None);
        for bad in [
            "upgrade = 1\n",
            "[upgrade]\nmin-age = \"7\"\n",
            "[upgrade]\nmin-age = 7\n",
            "[upgrade]\nmax-age = \"7d\"\n",
        ] {
            let err = read(Some(bad)).unwrap_err();
            assert!(
                matches!(err, ProjectError::BadUpgrade { .. }),
                "{bad}: {err}"
            );
        }
        assert_eq!(parse_min_age("14d"), Some(14));
        assert_eq!(parse_min_age("d"), None);
        assert_eq!(parse_min_age("1w"), None);
    }

    #[test]
    fn an_unknown_key_names_the_known_ones() {
        let err = read(Some("builder = \"kix\"\nbuidler = \"nix\"\n"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("`buidler`"), "{err}");
        assert!(err.contains("supports: builder, library, upgrade"), "{err}");
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
            err.contains("which this project's flake did not configure"),
            "{err}"
        );
        assert!(
            err.contains(&format!(
                "kix upgrade --to {}",
                crate::version::running().release()
            )),
            "{err}"
        );
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
        assert!(err.contains("Kix selected the `kix` builder"), "{err}");
        assert!(
            err.contains("the Kix library evaluated with the `nix` builder"),
            "{err}"
        );

        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, Some("kix")).unwrap();
        check_agreement(BuilderKind::Nix, &BuilderSource::TestOverride, None).unwrap();
    }

    #[test]
    fn library_is_the_input_unless_set_to_self() {
        assert_eq!(read(Some("")).unwrap().library, Library::Input);
        assert_eq!(
            read(Some("library = \"input\"\n")).unwrap().library,
            Library::Input
        );
        assert_eq!(
            read(Some("library = \"self\"\n")).unwrap().library,
            Library::OwnFlake
        );
        let dir = project(Some("library = \"self\"\n"));
        assert_eq!(library_setting(dir.path()).unwrap(), Library::OwnFlake);
        assert_eq!(
            library_setting(Path::new("/nonexistent/project")).unwrap(),
            Library::Input
        );
    }

    #[test]
    fn an_unknown_library_names_both_values() {
        let dir = project(Some("library = \"kix\"\n"));
        let expected = format!(
            "{} sets library = \"kix\", which Kix does not know. Write library = \"input\" (the default: the flake input named kix holds the Kix library) or library = \"self\" (this flake provides the Kix library itself).",
            dir.path().join(FILE).display()
        );
        let err = ProjectConfig::read(Some(dir.path()), None).unwrap_err();
        assert_eq!(err.to_string(), expected);
        assert_eq!(
            library_setting(dir.path()).unwrap_err().to_string(),
            expected
        );
    }

    #[test]
    fn the_kix_key_is_refused_with_its_id() {
        let named = |v: &str| {
            format!(
                "Run these steps with Kix 0.10 or later, because `kix upgrade` in Kix 0.9 writes the kix line back. Delete the kix line from kix.toml, then run `kix upgrade --to {v}` to record the version this project uses now, then run `kix upgrade` to move to a newer version and review what changes."
            )
        };
        let unnamed = "Run these steps with Kix 0.10 or later, because `kix upgrade` in Kix 0.9 writes the kix line back. Delete the kix line from kix.toml, then run `kix upgrade --to <version>` with the version of Kix this project uses now, then run `kix upgrade` to move to a newer version and review what changes.";
        for (text, shown, next) in [
            ("kix = \"0.10\"\n", "kix = \"0.10\"", named("0.10")),
            (
                "builder = \"nix\"\nkix = \"0.10.0-rc.3\"\n",
                "kix = \"0.10.0-rc.3\"",
                named("0.10.0-rc.3"),
            ),
            ("kix = 0.8\n", "kix = 0.8", unnamed.to_string()),
            ("kix = \">=0.8\"\n", "kix = \">=0.8\"", unnamed.to_string()),
        ] {
            let dir = project(Some(text));
            let expected = format!(
                "[K4476] {} sets {shown}, but Kix now takes this project's version from the Kix library tag in flake.lock. {next}",
                dir.path().join(FILE).display()
            );
            let err = ProjectConfig::read(Some(dir.path()), None).unwrap_err();
            assert!(
                matches!(err, ProjectError::KixSettingRemoved { .. }),
                "{err}"
            );
            assert_eq!(err.to_string(), expected);
            // Selection reads kix.toml leniently, but still refuses the key.
            assert_eq!(kix_setting(dir.path()).unwrap_err().to_string(), expected);
        }
    }

    #[test]
    fn the_kix_key_also_renames_the_old_input() {
        let dir = project(Some("kix = \"0.9\"\n"));
        std::fs::write(
            dir.path().join(crate::flake_lock::FILE),
            r#"{"nodes":{"root":{"inputs":{"kixpkgs":"kixpkgs"}},"kixpkgs":{"original":{"type":"github","owner":"kix-run","repo":"kix"}}},"root":"root","version":7}"#,
        )
        .unwrap();
        let err = kix_setting(dir.path()).unwrap_err().to_string();
        assert!(
            err.contains("Delete the kix line from kix.toml, rename the flake input kixpkgs to kix in flake.nix, then run `kix upgrade --to 0.9`"),
            "{err}"
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
