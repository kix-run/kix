//! Run the version of Kix that the project names in `kix.toml`.
//!
//! This runs in `main()` before clap parses, because the Kix that should run
//! may take other arguments than this one. It reads `--flake` (or
//! `KIX_FLAKE`) from the raw arguments, reads the project's `kix.toml`, and
//! either runs here, `exec`s an installed version that meets the project's
//! `kix` setting, or installs one first.
//!
//! The hand-over between two versions of Kix is a contract that every
//! version keeps: the chooser `exec`s `<install>/bin/kix` with its own
//! arguments unchanged and sets [`SELECTED_BY_VAR`] to its own path. A Kix
//! that finds the variable set never selects again, which ends any loop, and
//! `kix --version` and `kix doctor` print who chose it. The library check
//! still runs in the chosen Kix, so a project whose requirement it does not
//! meet still gets told.

use std::ffi::{OsStr, OsString};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

use kix::installs::{self, Install};
use kix::project::{self, KixSetting};
use kix::release;
use kix::version::policy::{self, Requirement};
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
}

/// The global flags that take a value, and how many.
const VALUE_FLAGS: &[(&str, usize)] = &[
    ("--output", 1),
    ("--context", 1),
    ("--flake", 1),
    ("--override-input", 2),
];

/// The short global flags that take a value.
const SHORT_VALUE_FLAGS: &[char] = &['o'];

/// Read `args` (with the program name first) the way clap will, as far as
/// selection needs.
pub fn scan(args: &[OsString]) -> Scan {
    let mut scan = Scan::default();
    let args: Vec<String> = args
        .iter()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        i += 1;
        if arg == "--" {
            break;
        }
        if let Some(long) = arg.strip_prefix("--") {
            let (name, attached) = match long.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (long, None),
            };
            match name {
                "help" => scan.help = true,
                "version" if scan.command.is_none() => scan.version = true,
                _ => {}
            }
            let takes = VALUE_FLAGS
                .iter()
                .find(|(flag, _)| flag.strip_prefix("--") == Some(name))
                .map(|(_, n)| *n);
            if let Some(n) = takes {
                let values: Vec<&str> = attached
                    .into_iter()
                    .chain(args[i..].iter().map(String::as_str))
                    .take(n)
                    .collect();
                i += n - usize::from(attached.is_some());
                if name == "flake" {
                    scan.flake = values.first().map(|v| v.to_string());
                }
            }
            continue;
        }
        if let Some(shorts) = arg.strip_prefix('-').filter(|s| !s.is_empty()) {
            for (at, c) in shorts.char_indices() {
                match c {
                    'h' => scan.help = true,
                    'V' if scan.command.is_none() => scan.version = true,
                    _ => {}
                }
                if SHORT_VALUE_FLAGS.contains(&c) {
                    if at + c.len_utf8() == shorts.len() {
                        i += 1;
                    }
                    break;
                }
            }
            continue;
        }
        if scan.command.is_none() {
            scan.command = Some(arg.to_string());
        }
    }
    scan
}

impl Scan {
    /// Return whether this command runs in whatever Kix the user started:
    /// managing versions, shell completions, project setup, and help.
    pub fn skips_selection(&self) -> bool {
        self.help
            || matches!(
                self.command.as_deref(),
                Some("self" | "completions" | "init" | "help")
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

/// What to do about the project's `kix` setting.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    RunHere,
    Exec(Install),
    Install(Requirement),
    Refuse(String),
}

/// Decide which Kix runs a project that needs `req`. `auto_install` is the
/// value of [`AUTO_INSTALL_VAR`].
pub fn decide(
    req: Option<&Requirement>,
    running: &Version,
    installed: &[Install],
    auto_install: Option<&OsStr>,
    selected_by: Option<&OsStr>,
) -> Decision {
    if selected_by.is_some() {
        return Decision::RunHere;
    }
    let Some(req) = req else {
        return Decision::RunHere;
    };
    let versions: Vec<Version> = installed.iter().map(|i| i.version.clone()).collect();
    let chosen = policy::choose(req, &versions);
    // A newer installed patch wins even when this Kix meets the requirement,
    // so installing a patch is enough to move a project onto it.
    if policy::satisfies(req, running) && chosen.as_ref().is_none_or(|c| c <= running) {
        return Decision::RunHere;
    }
    if let Some(chosen) = chosen {
        let install = installed
            .iter()
            .find(|i| i.version == chosen)
            .expect("choose returns one of the installed versions");
        return Decision::Exec(install.clone());
    }
    if auto_install_on(auto_install) {
        Decision::Install(req.clone())
    } else {
        Decision::Refuse(format!(
            "This project needs Kix {req} (kix.toml), and no Kix {req} is installed. Automatic installs are off ({AUTO_INSTALL_VAR}={}). Run `kix self install {req}`.",
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

/// Read the project's `kix` setting for `args`, or `None` when the command
/// reads no local project or the project sets none.
fn kix_setting(scan: &Scan) -> miette::Result<Option<KixSetting>> {
    let flake = raw_flake(scan, std::env::var_os("KIX_FLAKE").as_deref());
    let Some(dir) = crate::commands::project_dir(&flake) else {
        return Ok(None);
    };
    project::kix_setting(&dir).map_err(|e| miette!("{e}"))
}

/// Run the version of Kix the project in `args` needs, and print the version
/// for `kix --version`. Return only when the command runs in this process.
pub fn run(args: &[OsString]) -> miette::Result<Outcome> {
    let scan = scan(args);
    if scan.skips_selection() {
        return Ok(Outcome::RunHere);
    }
    let selected_by = std::env::var_os(SELECTED_BY_VAR).filter(|v| !v.is_empty());
    let setting = kix_setting(&scan)?;
    let req = setting.as_ref().map(|s| &s.requirement);
    // Listing the installs is one directory read, and only a project that
    // names a Kix needs it.
    let installed = if selected_by.is_none() && req.is_some() {
        installs::installed()
    } else {
        Vec::new()
    };
    let auto_install = std::env::var_os(AUTO_INSTALL_VAR);
    let decision = decide(
        req,
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
            print_version(selected_by.as_deref(), setting.as_ref());
            if let Some(req) = req {
                let next = if auto_install_on(auto_install.as_deref()) {
                    "Any other kix command installs it.".to_string()
                } else {
                    format!("Run `kix self install {req}`.")
                };
                eprintln!("  this project needs Kix {req}, which is not installed. {next}");
            }
            return Ok(Outcome::PrintedVersion);
        }
        Decision::Refuse(message) => return Err(miette!("{message}")),
        Decision::Install(req) => {
            let system = release::system().map_err(|e| miette!("{e}"))?;
            let installed = release::install(&req, &system, &release::Source::from_env(), &|v| {
                eprintln!("Installing Kix {} (this project needs {req})", v.release())
            })
            .map_err(|e| miette!("{e}"))?;
            return Err(exec(&installed.install, args));
        }
    }
    if scan.version {
        print_version(selected_by.as_deref(), setting.as_ref());
        return Ok(Outcome::PrintedVersion);
    }
    Ok(Outcome::RunHere)
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
fn print_version(selected_by: Option<&OsStr>, setting: Option<&KixSetting>) {
    println!("kix {}", version::running());
    if let Some(by) = selected_by {
        let by = Path::new(by).display();
        match setting {
            Some(KixSetting { requirement, path }) => eprintln!(
                "  chosen by kix = \"{requirement}\" in {} (started from {by})",
                path.display()
            ),
            None => eprintln!("  started from {by}"),
        }
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
        let minor = |m| Requirement::Minor(0, m);

        assert_eq!(
            decide(None, &running, &installed, None, None),
            Decision::RunHere
        );
        assert_eq!(
            decide(Some(&minor(8)), &running, &installed, None, None),
            Decision::RunHere
        );
        // A newer installed patch of the same minor wins, and an older one
        // does not.
        let with_patches = [install("0.8.3"), install("0.8.6")];
        assert_eq!(
            decide(Some(&minor(8)), &running, &with_patches, None, None),
            Decision::Exec(install("0.8.6"))
        );
        assert_eq!(
            decide(Some(&minor(8)), &running, &with_patches[..1], None, None),
            Decision::RunHere
        );
        assert_eq!(
            decide(Some(&minor(9)), &running, &installed, None, None),
            Decision::Exec(install("0.9.3"))
        );
        assert_eq!(
            decide(
                Some(&Requirement::Exact(v("0.9.1"))),
                &running,
                &installed,
                None,
                None
            ),
            Decision::Exec(install("0.9.1"))
        );
        assert_eq!(
            decide(Some(&minor(10)), &running, &installed, None, None),
            Decision::Install(minor(10))
        );
        assert_eq!(
            decide(
                Some(&minor(10)),
                &running,
                &installed,
                Some(OsStr::new("no")),
                None
            ),
            Decision::Refuse(
                "This project needs Kix 0.10 (kix.toml), and no Kix 0.10 is installed. Automatic installs are off (KIX_AUTO_INSTALL=no). Run `kix self install 0.10`.".into()
            )
        );
        // A chosen Kix never selects again, even when it does not meet the
        // project.
        assert_eq!(
            decide(
                Some(&minor(9)),
                &running,
                &installed,
                None,
                Some(OsStr::new("/usr/bin/kix"))
            ),
            Decision::RunHere
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
