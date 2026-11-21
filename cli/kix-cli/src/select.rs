//! Run the version of Kix that the project's `flake.lock` pins.
//!
//! This runs in `main()` before clap parses, because the Kix that should run
//! may take other arguments than this one. It reads `--flake` (or
//! `KIX_FLAKE`) and `--override-input` from the raw arguments, reads the
//! release tag of the project's `kix` input from `flake.lock`
//! (`kix::flake_lock`), and either runs here, `exec`s the installed version
//! of that tag, or installs it first. A project with a development library
//! runs here.
//!
//! The hand-over between two versions of Kix is a contract that every
//! version keeps: the chooser `exec`s `<install>/bin/kix` with its own
//! arguments unchanged and sets [`SELECTED_BY_VAR`] to its own path. A Kix
//! that finds the variable set never selects again, which ends any loop, and
//! `kix --version` and `kix doctor` print who chose it. The library check
//! still runs in the chosen Kix, so a `flake.nix` that moved its tag after
//! the choice still gets told.

use std::ffi::{OsStr, OsString};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

use kix::flake_lock::{self, LockError, ProjectKix};
use kix::installs::{self, Install};
use kix::release;
use kix::version::policy::Requirement;
use kix::version::{self, Version};
use miette::miette;

/// The variable a chooser sets to its own path when it hands over.
pub const SELECTED_BY_VAR: &str = "KIX_SELECTED_BY";

/// The variable that turns off installing a missing version.
pub const AUTO_INSTALL_VAR: &str = "KIX_AUTO_INSTALL";

/// What [`run`] did, when it returns at all.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The command runs in this process.
    RunHere,
    /// `kix --version` printed the version, and Kix should exit.
    PrintedVersion,
}

/// What the raw arguments say before clap reads them.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Scan {
    /// The last `--flake` value.
    pub flake: Option<String>,
    /// The first argument that is not a global flag or its value: the
    /// subcommand.
    pub command: Option<String>,
    /// `-h` or `--help` appears before `--`.
    pub help: bool,
    /// `-V` or `--version` appears before the subcommand.
    pub version: bool,
    /// Each `--override-input` pair.
    pub overrides: Vec<(String, String)>,
    /// The cluster the command acts on, for a command that takes one.
    pub cluster: Option<String>,
}

/// The name clap gives the argument that holds a command's cluster. A
/// command acts on a cluster when its first positional argument has this
/// name.
pub const CLUSTER_ARG: &str = "cluster";

/// Return how many of the words after a flag are its values.
fn values_of(arg: &clap::Arg) -> usize {
    if !arg.get_action().takes_values() {
        return 0;
    }
    arg.get_num_args().map_or(1, |n| n.min_values().max(1))
}

/// Return the flag of `command` that a person writes as `--<name>`.
fn long_flag<'a>(command: &'a clap::Command, name: &str) -> Option<&'a clap::Arg> {
    command.get_arguments().find(|a| {
        a.get_long() == Some(name)
            || a.get_all_aliases()
                .is_some_and(|aliases| aliases.contains(&name))
    })
}

/// Return the flag of `command` that a person writes as `-<c>`.
fn short_flag(command: &clap::Command, c: char) -> Option<&clap::Arg> {
    command.get_arguments().find(|a| {
        a.get_short() == Some(c)
            || a.get_all_short_aliases()
                .is_some_and(|aliases| aliases.contains(&c))
    })
}

/// Return whether the first positional argument of `command` is a cluster.
fn takes_cluster(command: &clap::Command) -> bool {
    command
        .get_positionals()
        .find(|a| a.get_index() == Some(1))
        .is_some_and(|a| a.get_id() == CLUSTER_ARG)
}

/// Read `args` (with the program name first) the way clap will, as far as
/// selection needs.
///
/// The scan reads the definition of the command line to learn which flags
/// take a value, which words are commands, and which commands take a
/// cluster, so a new command or flag needs no change here.
pub fn scan(args: &[OsString]) -> Scan {
    let mut root = crate::cli::command();
    // Building copies each global flag into every command.
    root.build();
    scan_with(&root, args)
}

fn scan_with(root: &clap::Command, args: &[OsString]) -> Scan {
    let mut scan = Scan::default();
    let args: Vec<String> = args
        .iter()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    // The command the words so far have reached, or `None` after a word that
    // is no command of Kix, which is a plugin with arguments of its own.
    let mut at = Some(root);
    let mut positionals = 0;
    // After `--` every word is a positional, as clap reads it.
    let mut flags = true;
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        i += 1;
        if flags && arg == "--" {
            flags = false;
            continue;
        }
        if flags && let Some(long) = arg.strip_prefix("--") {
            let (name, attached) = match long.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (long, None),
            };
            match name {
                "help" => scan.help = true,
                "version" if scan.command.is_none() => scan.version = true,
                _ => {}
            }
            let n = at
                .and_then(|c| long_flag(c, name))
                .or_else(|| long_flag(root, name))
                .map_or(0, values_of);
            if n > 0 {
                let values: Vec<&str> = attached
                    .into_iter()
                    .chain(args[i..].iter().map(String::as_str))
                    .take(n)
                    .collect();
                i += n - usize::from(attached.is_some());
                if name == "flake" {
                    scan.flake = values.first().map(|v| v.to_string());
                }
                if name == "override-input"
                    && let [input, url] = values[..]
                {
                    scan.overrides.push((input.to_string(), url.to_string()));
                }
            }
            continue;
        }
        if flags && let Some(shorts) = arg.strip_prefix('-').filter(|s| !s.is_empty()) {
            for (pos, c) in shorts.char_indices() {
                match c {
                    'h' => scan.help = true,
                    'V' if scan.command.is_none() => scan.version = true,
                    _ => {}
                }
                let n = at
                    .and_then(|cmd| short_flag(cmd, c))
                    .or_else(|| short_flag(root, c))
                    .map_or(0, values_of);
                if n > 0 {
                    // The rest of the word is the value, or else the next word.
                    if pos + c.len_utf8() == shorts.len() {
                        i += n;
                    }
                    break;
                }
            }
            continue;
        }
        if scan.command.is_none() {
            scan.command = Some(arg.to_string());
        }
        let Some(command) = at else { continue };
        if command.has_subcommands() {
            at = command.find_subcommand(arg);
            continue;
        }
        positionals += 1;
        if positionals == 1 && takes_cluster(command) {
            scan.cluster = Some(arg.to_string());
        }
    }
    scan
}

impl Scan {
    /// Return whether this command runs in whatever Kix the user started:
    /// managing versions, upgrading the project, shell completions, project
    /// setup, and help.
    pub fn skips_selection(&self) -> bool {
        self.help
            || matches!(
                self.command.as_deref(),
                Some("self" | "upgrade" | "completions" | "init" | "help")
            )
    }
}

/// Return the flake the command reads: `--flake`, else `KIX_FLAKE`, else `.`.
pub fn raw_flake(scan: &Scan, env_flake: Option<&OsStr>) -> String {
    scan.flake
        .clone()
        .or_else(|| {
            env_flake
                .filter(|v| !v.is_empty())
                .map(|v| v.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| ".".to_string())
}

/// What to do about the Kix a project uses.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    RunHere,
    Exec(Install),
    Install(Version),
    Refuse(String),
}

/// Decide which Kix runs a project that uses `kix`, or `None` when the
/// command reads no local project. `auto_install` is the value of
/// [`AUTO_INSTALL_VAR`].
pub fn decide(
    kix: Option<&ProjectKix>,
    running: &Version,
    installed: &[Install],
    auto_install: Option<&OsStr>,
    selected_by: Option<&OsStr>,
) -> Decision {
    if selected_by.is_some() {
        return Decision::RunHere;
    }
    let Some(ProjectKix::Release(wanted)) = kix else {
        return Decision::RunHere;
    };
    if wanted == running {
        return Decision::RunHere;
    }
    if let Some(install) = installed.iter().find(|i| &i.version == wanted) {
        return Decision::Exec(install.clone());
    }
    if auto_install_on(auto_install) {
        Decision::Install(wanted.clone())
    } else {
        let wanted = wanted.release();
        Decision::Refuse(format!(
            "This project uses Kix {wanted} (flake.lock), and Kix {wanted} is not installed. Automatic installs are off ({AUTO_INSTALL_VAR}={}). Run `kix self install {wanted}`.",
            auto_install.unwrap_or_default().to_string_lossy()
        ))
    }
}

/// Return whether installing a missing version is on: it is unless
/// [`AUTO_INSTALL_VAR`] is `0`, `false`, or `no`.
pub fn auto_install_on(value: Option<&OsStr>) -> bool {
    !value
        .map(|v| v.to_string_lossy().trim().to_ascii_lowercase())
        .is_some_and(|v| matches!(v.as_str(), "0" | "false" | "no"))
}

/// Return the Kix the project in `scan` uses, or `None` when the command
/// reads no local project: `--flake` names a remote flake, or the
/// directory has no `flake.nix`.
fn project_kix(scan: &Scan) -> Option<(String, Result<ProjectKix, LockError>)> {
    let flake = raw_flake(scan, std::env::var_os("KIX_FLAKE").as_deref());
    let dir = crate::commands::project_dir(&flake)?;
    if !dir.join("flake.nix").is_file() {
        return None;
    }
    Some(match input_in(&dir, scan) {
        Ok(input) => {
            let kix = flake_lock::project_kix_on(&dir, &overrides(scan), &input);
            (input, kix)
        }
        Err(e) => (flake_lock::INPUT.to_string(), Err(e)),
    })
}

/// Return the input whose Kix runs the command `scan` found, in the project
/// in `dir`. A project with a `[versions]` table uses the input that lists
/// the cluster. A command that names no cluster, or names a word the table
/// does not list, uses the input `kix`, and the chosen Kix judges the word
/// once it has parsed the command.
fn input_in(dir: &Path, scan: &Scan) -> Result<String, LockError> {
    let setting = |e: kix::versions::VersionsError| LockError::Setting(e.to_string());
    let versions = kix::versions::Versions::read(dir).map_err(setting)?;
    // A table that names an input the lock does not hold is wrong for every
    // cluster, so it is reported before the lock of any one input is read.
    if let Some(versions) = &versions
        && let Ok(lock) = flake_lock::read(dir)
    {
        versions
            .check(&lock, &kix::versions::flake_text(dir))
            .map_err(setting)?;
    }
    let input = match (&versions, &scan.cluster) {
        (Some(versions), Some(cluster)) => versions.input_of(cluster),
        _ => None,
    };
    Ok(input.unwrap_or(flake_lock::INPUT).to_string())
}

/// Return the `--override-input` pairs, or else the pairs in
/// `KIX_OVERRIDE_INPUT`, as `main` reads them.
fn overrides(scan: &Scan) -> Vec<(String, String)> {
    if !scan.overrides.is_empty() {
        return scan.overrides.clone();
    }
    let words: Vec<String> = std::env::var("KIX_OVERRIDE_INPUT")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    words
        .chunks_exact(2)
        .map(|c| (c[0].clone(), c[1].clone()))
        .collect()
}

/// Run the version of Kix the project in `args` uses, and print the version
/// for `kix --version`. Return only when the command runs in this process.
pub fn run(args: &[OsString]) -> miette::Result<Outcome> {
    let scan = scan(args);
    if scan.skips_selection() {
        return Ok(Outcome::RunHere);
    }
    let selected_by = std::env::var_os(SELECTED_BY_VAR).filter(|v| !v.is_empty());
    // A chosen Kix never selects again, so it reads no lock.
    let kix = match selected_by {
        Some(_) => None,
        None => project_kix(&scan),
    };
    let input = kix
        .as_ref()
        .map_or(flake_lock::INPUT.to_string(), |(input, _)| input.clone());
    let kix = match kix.map(|(_, kix)| kix) {
        None => None,
        Some(Ok(kix)) => Some(kix),
        // `kix --version` still prints the version.
        Some(Err(e)) if scan.version => {
            print_version(selected_by.as_deref());
            eprintln!("  {e}");
            return Ok(Outcome::PrintedVersion);
        }
        Some(Err(e)) => return Err(miette!("{e}")),
    };
    // Listing the installs is one directory read, and only a project on a
    // release needs it.
    let installed = if matches!(kix, Some(ProjectKix::Release(_))) {
        installs::installed()
    } else {
        Vec::new()
    };
    let auto_install = std::env::var_os(AUTO_INSTALL_VAR);
    let decision = decide(
        kix.as_ref(),
        version::running(),
        &installed,
        auto_install.as_deref(),
        selected_by.as_deref(),
    );
    match decision {
        Decision::RunHere => {}
        Decision::Exec(install) => return Err(exec(&install, args)),
        // `kix --version` reports what is installed and never downloads.
        Decision::Install(_) | Decision::Refuse(_) if scan.version => {
            print_version(selected_by.as_deref());
            let wanted = wanted_release(kix.as_ref()).unwrap_or_default();
            let next = if auto_install_on(auto_install.as_deref()) {
                "Any other kix command installs it.".to_string()
            } else {
                format!("Run `kix self install {wanted}`.")
            };
            eprintln!("  this project uses Kix {wanted}, which is not installed. {next}");
            return Ok(Outcome::PrintedVersion);
        }
        Decision::Refuse(message) => return Err(miette!("{message}")),
        Decision::Install(wanted) => {
            let system = release::system().map_err(|e| miette!("{e}"))?;
            let req = Requirement::Exact(wanted.clone());
            let installed = release::install(&req, &system, &release::Source::from_env(), &|v| {
                eprintln!(
                    "Installing Kix {} (this project uses {})",
                    v.release(),
                    wanted.release()
                )
            })
            .map_err(|e| miette!("{e}"))?;
            for warning in &installed.warnings {
                eprintln!("warning: {warning}");
            }
            return Err(exec(&installed.install, args));
        }
    }
    if scan.version {
        print_version(selected_by.as_deref());
        if let Some(ProjectKix::Development(from)) = &kix {
            eprintln!(
                "  this project uses a development Kix library: {}",
                from.describe(&input)
            );
        }
        return Ok(Outcome::PrintedVersion);
    }
    if let Some(ProjectKix::Development(from)) = &kix {
        eprintln!(
            "note: this project uses a development Kix library ({}), so Kix {} runs it without checking its version.",
            from.describe(&input),
            version::running().release()
        );
    }
    Ok(Outcome::RunHere)
}

/// Return the release a project on a release uses.
fn wanted_release(kix: Option<&ProjectKix>) -> Option<String> {
    match kix {
        Some(ProjectKix::Release(v)) => Some(v.release()),
        _ => None,
    }
}

/// Replace this process with the Kix of `install`, passing `args` on as they
/// are. Return the error when that fails.
fn exec(install: &Install, args: &[OsString]) -> miette::Report {
    let bin = install.bin();
    let chooser = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("kix"));
    let error = std::process::Command::new(&bin)
        .args(&args[1..])
        .env(SELECTED_BY_VAR, &chooser)
        .exec();
    miette!(
        "could not run Kix {} at {}: {error}",
        install.version.release(),
        bin.display()
    )
}

/// Print `kix --version`. The first line is exactly `kix <version>`, which
/// the release job checks. The lines about who chose this Kix and which Kix
/// is on PATH go to stderr, so scripts that read the version keep working.
fn print_version(selected_by: Option<&OsStr>) {
    println!("kix {}", version::running());
    if let Some(by) = selected_by {
        eprintln!("  started from {}", Path::new(by).display());
    }
    let me = std::env::current_exe().and_then(|p| p.canonicalize()).ok();
    if let Some(path) = installs::on_path()
        && Some(&path) != me.as_ref()
    {
        match installs::version_of(&path) {
            Some(v) if &v != version::running() => {
                eprintln!("  kix on PATH is {} ({})", v.release(), path.display())
            }
            Some(_) => {}
            None => eprintln!("  kix on PATH is {}", path.display()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(line: &str) -> Vec<OsString> {
        std::iter::once("kix")
            .chain(line.split_whitespace())
            .map(OsString::from)
            .collect()
    }

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    fn install(version: &str) -> Install {
        Install {
            version: v(version),
            dir: PathBuf::from(format!("/data/{version}")),
        }
    }

    #[test]
    fn the_cluster_is_the_first_bare_word_after_the_command_words() {
        let cases: &[(&str, Option<&str>)] = &[
            ("deploy prod", Some("prod")),
            ("deploy prod --yes", Some("prod")),
            ("--flake p deploy prod", Some("prod")),
            ("export staging --out prod", Some("staging")),
            ("export --out prod staging", Some("staging")),
            ("deploy --plan prod staging", Some("staging")),
            ("status --package prod staging", Some("staging")),
            ("logs -c prod staging web", Some("staging")),
            ("logs staging prod", Some("staging")),
            ("list resources prod", Some("prod")),
            ("list clusters", None),
            ("compliance audit prod --out staging", Some("prod")),
            ("migrate domain prod", Some("prod")),
            ("status", None),
            ("status prod", Some("prod")),
            ("rollback -- prod", Some("prod")),
            ("deploy --yes -- prod", Some("prod")),
            ("rollback prod -- --yes", Some("prod")),
            ("pf prod web 80", Some("prod")),
            ("pin set prod", None),
            ("upgrade prod --to kix", None),
            ("self install prod", None),
            ("some-plugin prod", None),
        ];
        for (line, cluster) in cases {
            assert_eq!(scan(&args(line)).cluster.as_deref(), *cluster, "{line}");
        }
    }

    #[test]
    fn the_flake_and_the_command_are_found_among_the_global_flags() {
        let cases: &[(&str, Option<&str>, Option<&str>)] = &[
            ("list clusters", None, Some("list")),
            ("--flake ../p build c", Some("../p"), Some("build")),
            ("--flake=../p build c", Some("../p"), Some("build")),
            ("build c --flake /abs", Some("/abs"), Some("build")),
            ("-o json --context prod plan c", None, Some("plan")),
            ("-ojson -vv plan c", None, Some("plan")),
            ("-vo json plan c", None, Some("plan")),
            (
                "--override-input kixpkgs path:/x self list",
                None,
                Some("self"),
            ),
            (
                "--override-input=kixpkgs path:/x --flake p deploy c",
                Some("p"),
                Some("deploy"),
            ),
            (
                "-q --no-color --no-cache --flake a --flake b status c",
                Some("b"),
                Some("status"),
            ),
            ("logs c -- --flake x", None, Some("logs")),
            ("", None, None),
        ];
        for (line, flake, command) in cases {
            let s = scan(&args(line));
            assert_eq!(s.flake.as_deref(), *flake, "{line}");
            assert_eq!(s.command.as_deref(), *command, "{line}");
        }
    }

    #[test]
    fn self_completions_init_and_help_skip_selection() {
        for line in [
            "self list",
            "--flake p self install 0.8",
            "--flake p upgrade --dry-run",
            "completions bash",
            "init",
            "help",
            "build c --help",
            "-h",
            "-vh",
        ] {
            assert!(scan(&args(line)).skips_selection(), "{line}");
        }
        for line in [
            "build c",
            "--version",
            "doctor",
            "list clusters",
            "logs c -- -h",
        ] {
            assert!(!scan(&args(line)).skips_selection(), "{line}");
        }
    }

    #[test]
    fn version_counts_only_before_the_subcommand() {
        assert!(scan(&args("--version")).version);
        assert!(scan(&args("-V")).version);
        assert!(scan(&args("--flake p --version")).version);
        assert!(!scan(&args("build --version")).version);
        assert!(!scan(&args("build c")).version);
    }

    #[test]
    fn the_flake_falls_back_to_the_variable_then_the_directory() {
        let none = Scan::default();
        assert_eq!(raw_flake(&none, None), ".");
        assert_eq!(raw_flake(&none, Some(OsStr::new("/p"))), "/p");
        assert_eq!(raw_flake(&none, Some(OsStr::new(""))), ".");
        let flag = scan(&args("--flake ../q list clusters"));
        assert_eq!(raw_flake(&flag, Some(OsStr::new("/p"))), "../q");
    }

    #[test]
    fn decisions() {
        let running = v("0.8.4+250");
        let installed = [install("0.9.1"), install("0.9.3"), install("0.7.0")];
        let release = |s: &str| ProjectKix::Release(v(s));
        let development = ProjectKix::Development(flake_lock::Development::OwnLibrary);

        assert_eq!(
            decide(None, &running, &installed, None, None),
            Decision::RunHere
        );
        assert_eq!(
            decide(Some(&development), &running, &installed, None, None),
            Decision::RunHere
        );
        assert_eq!(
            decide(Some(&release("0.8.4")), &running, &installed, None, None),
            Decision::RunHere
        );
        // The exact version runs, never a newer patch.
        assert_eq!(
            decide(Some(&release("0.9.1")), &running, &installed, None, None),
            Decision::Exec(install("0.9.1"))
        );
        assert_eq!(
            decide(Some(&release("0.8.5")), &running, &installed, None, None),
            Decision::Install(v("0.8.5"))
        );
        assert_eq!(
            decide(
                Some(&release("0.10.0")),
                &running,
                &installed,
                Some(OsStr::new("no")),
                None
            ),
            Decision::Refuse(
                "This project uses Kix 0.10.0 (flake.lock), and Kix 0.10.0 is not installed. Automatic installs are off (KIX_AUTO_INSTALL=no). Run `kix self install 0.10.0`.".into()
            )
        );
        // A chosen Kix never selects again.
        assert_eq!(
            decide(
                Some(&release("0.9.1")),
                &running,
                &installed,
                None,
                Some(OsStr::new("/usr/bin/kix"))
            ),
            Decision::RunHere
        );
    }

    #[test]
    fn overrides_are_read_from_the_arguments() {
        let s = scan(&args("--override-input kix path:/x build c"));
        assert_eq!(s.overrides, [("kix".to_string(), "path:/x".to_string())]);
        let s = scan(&args("--override-input=nixpkgs path:/n --flake p build c"));
        assert_eq!(
            s.overrides,
            [("nixpkgs".to_string(), "path:/n".to_string())]
        );
    }

    #[test]
    fn auto_install_is_on_unless_turned_off() {
        assert!(auto_install_on(None));
        assert!(auto_install_on(Some(OsStr::new("1"))));
        for off in ["0", "false", "no", "NO", "False"] {
            assert!(!auto_install_on(Some(OsStr::new(off))), "{off}");
        }
    }
}
