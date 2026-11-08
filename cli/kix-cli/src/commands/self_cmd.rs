//! `kix self`: install, list, prune, and update the versions of Kix under the
//! data directory ([`kix::installs`]).

use std::path::Path;

use kix::installs::{self, Install, Receipt};
use kix::release::{self, Source};
use kix::version;
use kix::version::policy::Requirement;
use miette::miette;

use crate::cli::SelfCommand;

pub fn run(command: &SelfCommand) -> miette::Result<()> {
    match command {
        SelfCommand::Install { version } => install(version),
        SelfCommand::List => {
            list();
            Ok(())
        }
        SelfCommand::Prune { keep, dry_run } => prune(*keep, *dry_run),
        SelfCommand::Update => update(),
    }
}

fn install(text: &str) -> miette::Result<()> {
    let req: Requirement = text.parse().map_err(|e| miette!("{e}"))?;
    let installed = fetch(&req)?;
    let v = installed.install.version.release();
    let dir = installed.install.dir.display();
    if installed.downloaded {
        println!("Installed Kix {v} to {dir}");
    } else {
        println!("Kix {v} is already installed in {dir}");
    }
    Ok(())
}

fn fetch(req: &Requirement) -> miette::Result<release::Installed> {
    let system = release::system().map_err(|e| miette!("{e}"))?;
    release::install(req, &system, &Source::from_env(), &|v| {
        eprintln!("Installing Kix {}", v.release())
    })
    .map_err(|e| miette!("{e}"))
}

fn list() {
    let Some(data) = installs::data_dir() else {
        println!("No versions of Kix are installed. {}", installs::NO_HOME);
        return;
    };
    let all = installs::installed();
    if all.is_empty() {
        println!("No versions of Kix are installed in {}", data.display());
        return;
    }
    let running = installs::running_install();
    let on_path = installs::on_path();
    for install in &all {
        let mark = if running.as_ref() == Some(install) {
            "*"
        } else {
            " "
        };
        let path_note = if is_bin(install, on_path.as_deref()) {
            " (on PATH)"
        } else {
            ""
        };
        println!(
            "{mark} {}  {}{path_note}",
            install.version.release(),
            install.dir.display()
        );
    }
}

/// Return whether `bin`, a resolved path, is the `kix` of `install`.
fn is_bin(install: &Install, bin: Option<&Path>) -> bool {
    bin.is_some_and(|bin| install.bin().canonicalize().is_ok_and(|b| b == bin))
}

/// Return the installs prune removes: all but the newest `keep`, the running
/// one, and the one on PATH. `all` is newest first.
fn to_prune<'a>(
    all: &'a [Install],
    keep: usize,
    running: Option<&Install>,
    on_path: Option<&Path>,
) -> Vec<&'a Install> {
    all.iter()
        .skip(keep)
        .filter(|i| Some(*i) != running && !is_bin(i, on_path))
        .collect()
}

fn prune(keep: usize, dry_run: bool) -> miette::Result<()> {
    let all = installs::installed();
    let running = installs::running_install();
    let on_path = installs::on_path();
    let remove = to_prune(&all, keep, running.as_ref(), on_path.as_deref());
    if remove.is_empty() {
        println!(
            "Nothing to remove. {} versions of Kix are installed.",
            all.len()
        );
        return Ok(());
    }
    for install in remove {
        let v = install.version.release();
        let dir = install.dir.display();
        if dry_run {
            println!("Would remove Kix {v} ({dir})");
        } else {
            installs::remove_tree(&install.dir)
                .map_err(|e| miette!("could not remove Kix {v} from {dir}: {e}"))?;
            println!("Removed Kix {v} ({dir})");
        }
    }
    Ok(())
}

fn update() -> miette::Result<()> {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|e| miette!("could not find the running Kix: {e}"))?;
    let running = installs::running_install();
    let receipt = Receipt::read().filter(|r| r.installer == Receipt::SCRIPT);
    let Some((current, receipt)) = running.zip(receipt) else {
        return Err(miette!(
            "Kix {} at {} was not installed by the install script. Upgrade it the way you installed it, for example with nix profile upgrade kix",
            version::running().release(),
            exe.display()
        ));
    };
    let source = Source::from_env();
    let system = release::system().map_err(|e| miette!("{e}"))?;
    let latest = release::latest(&source, &system)
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| miette!("{source} lists no releases of Kix for {system} yet"))?;
    if latest <= current.version {
        println!("Kix {} is the newest release", current.version.release());
        return Ok(());
    }
    let installed = fetch(&Requirement::Exact(latest))?;
    let link = receipt
        .link
        .clone()
        .or_else(installs::link_path)
        .ok_or_else(|| miette!("{}", installs::NO_HOME))?;
    point_link(&link, &installed.install)?;
    Receipt {
        installer: Receipt::SCRIPT.to_string(),
        version: installed.install.version.release(),
        installed_at: Some(chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
        link: Some(link),
    }
    .write()
    .map_err(|e| miette!("could not write the install receipt: {e}"))?;
    println!(
        "Kix {} -> {}",
        current.version.release(),
        installed.install.version.release()
    );
    Ok(())
}

/// Point `link`, the install script's link, at `install`, replacing it in
/// one step so `kix` on PATH never goes missing.
fn point_link(link: &Path, install: &Install) -> miette::Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(link)
        && !meta.file_type().is_symlink()
    {
        return Err(miette!(
            "{} exists and was not installed by the install script. Remove it, then run `kix self update` again",
            link.display()
        ));
    }
    let dir = link
        .parent()
        .ok_or_else(|| miette!("{} has no parent directory", link.display()))?;
    std::fs::create_dir_all(dir).map_err(|e| miette!("could not create {}: {e}", dir.display()))?;
    let tmp = dir.join(format!(".kix.tmp-{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    std::os::unix::fs::symlink(install.bin(), &tmp)
        .and_then(|()| std::fs::rename(&tmp, link))
        .map_err(|e| {
            miette!(
                "could not point {} at Kix {}: {e}",
                link.display(),
                install.version.release()
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn install(version: &str) -> Install {
        Install {
            version: version.parse().unwrap(),
            dir: PathBuf::from(format!("/nonexistent/{version}")),
        }
    }

    #[test]
    fn prune_keeps_the_newest_and_the_running_one() {
        let all = [
            install("0.9.1"),
            install("0.9.0"),
            install("0.8.4"),
            install("0.7.0"),
        ];
        let names =
            |v: Vec<&Install>| -> Vec<String> { v.iter().map(|i| i.version.to_string()).collect() };
        assert_eq!(names(to_prune(&all, 2, None, None)), ["0.8.4", "0.7.0"]);
        assert_eq!(names(to_prune(&all, 2, Some(&all[3]), None)), ["0.8.4"]);
        assert!(to_prune(&all, 4, None, None).is_empty());
        assert_eq!(names(to_prune(&all, 0, Some(&all[0]), None)).len(), 3);
    }
}
