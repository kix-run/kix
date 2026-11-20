//! The state of one `kix upgrade` run, and pinning and building one step.

use std::path::{Path, PathBuf};

use kix::installs;
use kix::release::{self, Source};
use kix::version::Version;
use kix::version::policy::Requirement;
use miette::miette;

use super::halt::{Flow, Halt, refused};
use super::out::{self, Failed};
use super::pin::{self, edit_message};
use super::state::{Status, Step, UpgradeState};
use super::subprocess::{clusters, new_command_line, run_kix};
use super::{EXIT_BUILD_FAILED, EXIT_NEEDS_PERSON};
use crate::exit::Exit;

/// One cluster that failed to build.
pub(super) struct Failure {
    pub(super) cluster: String,
    /// What the build printed.
    pub(super) output: String,
    /// The file that holds `output`.
    pub(super) log: Option<PathBuf>,
}

/// The clusters that failed to build.
pub(super) type Failures = Vec<Failure>;

/// What [`Run::build_all`] did.
pub(super) struct Built {
    pub(super) clusters: Vec<String>,
    pub(super) failures: Failures,
}

/// The version the steps reached, or the step that failed and why.
pub(super) type Outcome = std::result::Result<Version, (Version, Failures)>;

/// One `kix upgrade` run: what it installed, and where it builds.
pub(super) struct Run {
    pub(super) dir: PathBuf,
    pub(super) source: Source,
    pub(super) work: PathBuf,
    pub(super) installed_here: Vec<installs::Install>,
    /// The version the upgrade started from.
    pub(super) from: Version,
    /// The version the project is pinned to now, whose release tag
    /// `flake.nix` may name.
    pub(super) pinned: Version,
    /// What `kix-upgrade.json` holds, once the steps begin.
    pub(super) state: Option<UpgradeState>,
    pub(super) verbose: bool,
}

impl Run {
    pub(super) fn state(&self) -> &UpgradeState {
        self.state.as_ref().expect("the steps run with a state")
    }

    pub(super) fn state_mut(&mut self) -> &mut UpgradeState {
        self.state.as_mut().expect("the steps run with a state")
    }

    pub(super) fn save(&self) -> Flow<()> {
        Ok(self.state().write(&self.dir).map_err(|e| miette!("{e}"))?)
    }

    /// Return the `kix` of `version`, installing it first when needed.
    pub(super) fn kix(&mut self, version: &Version) -> Flow<PathBuf> {
        if let Some(i) = installs::installed()
            .into_iter()
            .find(|i| &i.version == version)
        {
            return Ok(i.bin());
        }
        let system = release::system().map_err(|e| miette!("{e}"))?;
        // A withdrawn baseline installs with warnings meant for someone who
        // stays on it. The upgrade is leaving it, so they are not printed.
        let installed = release::install(
            &Requirement::Exact(version.clone()),
            &system,
            &self.source,
            &|_| {},
        );
        let installed = match installed {
            Ok(i) => i,
            // Once the steps began, the state is saved and a rerun resumes.
            Err(e) if self.state.is_some() => {
                let v = version.release();
                return Err(refused(format!(
                    "Installing Kix {v}... failed\n\nCannot download Kix {v}: {}.\nUpgrade state is saved in kix-upgrade.json (the {} baseline build is cached).\nNext: check your network connection, then run `kix upgrade` to resume at Kix {v}.",
                    e.to_string().trim_end_matches('.'),
                    self.from.release()
                )));
            }
            Err(e) => {
                println!("Installing Kix {}... failed", version.release());
                return Err(miette!("{e}").into());
            }
        };
        if installed.downloaded {
            println!("Installing Kix {}... ok", version.release());
            self.installed_here.push(installed.install.clone());
        }
        Ok(installed.install.bin())
    }

    /// Save the state as `status`, print `message`, remove what this run
    /// installed, and return the halt that exits with `code`.
    fn stop(&mut self, status: Status, message: &str, code: Exit) -> Halt {
        self.state_mut().status = status;
        if let Err(halt) = self.save() {
            return halt;
        }
        println!();
        println!("{message}");
        let (from, pinned) = (self.from.clone(), self.pinned.clone());
        self.prune(&from, &pinned);
        Halt::Stopped(code)
    }

    /// Return the text of the stop for an edit a person must make in
    /// `flake.nix`.
    fn edit_message(&self, edit: &kix::pin_library::HandEdit) -> String {
        let state = if self.pinned == self.from {
            format!(
                "flake.nix and flake.lock were not changed. Upgrade state is saved in kix-upgrade.json (the {} baseline build is cached).",
                self.from.release()
            )
        } else {
            format!(
                "flake.nix and flake.lock are pinned to Kix {} (the {} baseline build is cached).",
                self.pinned.release(),
                self.from.release()
            )
        };
        edit_message(edit, &state, "kix upgrade")
    }

    /// Set the result of the step in progress, and save the state.
    fn finish_step(&mut self, result: &str, failures: &Failures) -> Flow<()> {
        let step = self
            .state_mut()
            .steps
            .last_mut()
            .expect("a step is in progress");
        step.result = result.to_string();
        step.failed = failures.iter().map(|f| f.cluster.clone()).collect();
        self.save()
    }

    /// Pin the project to `version` and build every cluster. The target is
    /// installed only after Kix knows it can make the flake.nix edit. A
    /// first try of the target (`jump`) names the failed clusters only.
    fn step(&mut self, version: &Version, jump: bool) -> Flow<std::result::Result<(), Failures>> {
        self.state_mut().steps.push(Step {
            version: version.release(),
            result: "started".into(),
            failed: Vec::new(),
        });
        self.state_mut().status = Status::FixNeeded;
        self.save()?;
        let plan = match pin::prepare(&self.dir, Some(&self.pinned), version) {
            Ok(plan) => plan,
            Err(pin::PinError::Edit(edit)) => {
                let message = self.edit_message(&edit);
                return Err(self.stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON));
            }
            Err(pin::PinError::ByHand(message)) => {
                return Err(self.stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON));
            }
            Err(pin::PinError::Lock(message)) => {
                self.finish_step("failed", &Vec::new())?;
                return Err(self.stop(Status::FixNeeded, &message, EXIT_BUILD_FAILED));
            }
            Err(e) => return Err(miette!("{e}").into()),
        };
        let kix = self.kix(version)?;
        match pin::pin(Some(&self.pinned), version, &plan) {
            Ok(files) => {
                if !files.is_empty() {
                    println!(
                        "Pinned project to Kix {} (updated {})",
                        version.release(),
                        out::list(&files)
                    );
                }
                self.pinned = version.clone();
            }
            Err(pin::PinError::Lock(message)) => {
                self.finish_step("failed", &Vec::new())?;
                return Err(self.stop(Status::FixNeeded, &message, EXIT_BUILD_FAILED));
            }
            Err(pin::PinError::ByHand(message)) => {
                return Err(self.stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON));
            }
            Err(pin::PinError::Edit(edit)) => {
                let message = self.edit_message(&edit);
                return Err(self.stop(Status::EditNeeded, &message, EXIT_NEEDS_PERSON));
            }
            Err(e) => return Err(miette!("{e}").into()),
        }
        let out_dir = self.work.join(version.release());
        let built = self.build_all(&kix, version, &out_dir);
        let failed: Vec<String> = built.failures.iter().map(|f| f.cluster.clone()).collect();
        let how = if failed.is_empty() {
            None
        } else if jump {
            Some(Failed::Names(&failed))
        } else {
            Some(Failed::Count(&failed, built.clusters.len()))
        };
        println!(
            "{}",
            out::build_line(built.clusters.len(), version, false, None, how)
        );
        if built.failures.is_empty() {
            self.finish_step("ok", &Vec::new())?;
            Ok(Ok(()))
        } else {
            self.finish_step("failed", &built.failures)?;
            Ok(Err(built.failures))
        }
    }

    /// Move straight to `goal`. When the project does not build with it,
    /// take `steps` one at a time.
    pub(super) fn jump(&mut self, goal: &Version, steps: &[Version]) -> Flow<Outcome> {
        let single = steps.len() <= 1;
        match self.step(goal, !single)? {
            Ok(()) => Ok(Ok(goal.clone())),
            Err(failures) if single => Ok(Err((goal.clone(), failures))),
            Err(_) => {
                let plan: Vec<String> = steps.iter().map(Version::release).collect();
                println!(
                    "Stepping one minor release at a time ({}):",
                    plan.join(" -> ")
                );
                self.step_through(steps)
            }
        }
    }

    /// Take each of `steps` in turn, and stop at the first that fails.
    pub(super) fn step_through(&mut self, steps: &[Version]) -> Flow<Outcome> {
        let mut last = None;
        for v in steps {
            if let Err(failures) = self.step(v, false)? {
                return Ok(Err((v.clone(), failures)));
            }
            last = Some(v.clone());
        }
        Ok(Ok(last.expect("a stepping upgrade has at least one step")))
    }

    /// Build every cluster of the project with `kix`, Kix `version`, into
    /// `out/<cluster>`, keeping each failed cluster's output in a log file.
    pub(super) fn build_all(&self, kix: &Path, version: &Version, out: &Path) -> Built {
        let failure = |cluster: &str, output: String| Failure {
            cluster: cluster.to_string(),
            output,
            log: None,
        };
        if out.exists()
            && let Err(e) = installs::remove_tree(out)
        {
            return Built {
                clusters: Vec::new(),
                failures: vec![failure(
                    "(cluster list)",
                    format!("could not clear {}: {e}", out.display()),
                )],
            };
        }
        if let Some(parent) = out.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let names = match clusters(kix, &self.dir) {
            Ok(names) => names,
            Err(e) => {
                return Built {
                    clusters: Vec::new(),
                    failures: vec![failure("(cluster list)", e)],
                };
            }
        };
        let logs = self.work.join("logs").join(version.release());
        let mut failures = Vec::new();
        for cluster in &names {
            let dest = out.join(cluster);
            let dest_text = dest.display().to_string();
            let keep_metadata: &[&str] = if new_command_line(version) {
                &["--with-kix-metadata"]
            } else {
                &["--for", "audit"]
            };
            let args = [
                &["export", cluster.as_str(), "--out", &dest_text][..],
                keep_metadata,
            ]
            .concat();
            if let Err(output) = run_kix(kix, &self.dir, &args) {
                let path = logs.join(format!("{cluster}.log"));
                let log = std::fs::create_dir_all(&logs)
                    .and_then(|()| std::fs::write(&path, &output))
                    .ok()
                    .map(|()| path);
                failures.push(Failure {
                    cluster: cluster.clone(),
                    output,
                    log,
                });
            }
        }
        if failures.is_empty() {
            let _ = std::fs::create_dir_all(out);
        }
        Built {
            clusters: names,
            failures,
        }
    }

    /// Remove each version this run installed, except `from` and `kept`.
    pub(super) fn prune(&self, from: &Version, kept: &Version) {
        let mut first = true;
        for i in &self.installed_here {
            if &i.version == from || &i.version == kept {
                continue;
            }
            match installs::remove_tree(&i.dir) {
                Ok(()) if self.verbose => {
                    if first {
                        println!();
                        first = false;
                    }
                    println!("Removed temporary Kix {}.", i.version.release())
                }
                Ok(()) => {}
                Err(e) => {
                    tracing::warn!(path = %i.dir.display(), error = %e, "could not remove a version of Kix")
                }
            }
        }
    }
}

/// Return the directory `kix upgrade` keeps its builds of the project in
/// `dir` in, under Kix's cache directory.
pub(super) fn work_dir(dir: &Path) -> PathBuf {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(dir.as_os_str().as_encoded_bytes());
    let key: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    kix::eval::store::default_cache_dir()
        .join("upgrade")
        .join(key)
}
