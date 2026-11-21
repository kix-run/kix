//! Pin a project to a version of Kix: the release tag of the Kix library in
//! `flake.nix` and `flake.lock`, through [`kix::pin_library`].

use std::path::Path;

use kix::pin_library::{HandEdit, PinLibraryError, Plan};
use kix::version::Version;

use super::subject::input_command;

/// Why Kix could not pin the project. Each message is ready to print and
/// ends with a `Next:` line.
#[derive(Debug)]
pub enum PinError {
    /// Nix could not move `flake.lock`. Kix tried to put the files back.
    Lock(String),
    /// A person must change a file. Kix changed nothing, or put it back.
    ByHand(String),
    /// More than one url in `flake.nix` names the library's repository. Kix
    /// changed nothing.
    Edit(HandEdit),
    Other(String),
}

impl From<String> for PinError {
    fn from(message: String) -> Self {
        PinError::Other(message)
    }
}

impl std::fmt::Display for PinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PinError::Lock(m) | PinError::ByHand(m) | PinError::Other(m) => f.write_str(m),
            PinError::Edit(e) => write!(
                f,
                "flake.nix names the Kix library's repository on {} lines",
                e.lines.len()
            ),
        }
    }
}

/// Return how a message names the state the project stays in: the version
/// it is pinned to, or else its files as they are.
fn remains(current: Option<&Version>) -> String {
    match current {
        Some(v) => format!("flake.nix and flake.lock remain at Kix {}.", v.release()),
        None => "Kix did not change flake.nix or flake.lock.".to_string(),
    }
}

/// Work out how to pin the Kix library input `input` of the project in
/// `dir`, now pinned to `current`, to `version`, before Kix installs that
/// version or changes a file.
pub fn prepare(
    dir: &Path,
    input: &str,
    current: Option<&Version>,
    version: &Version,
) -> Result<Plan, PinError> {
    crate::commands::select_builder_for(dir)?;
    kix::runtime::runtime().map_err(|e| e.to_string())?;
    match kix::pin_library::plan(dir, input, version) {
        Ok(plan) => Ok(plan),
        Err(PinLibraryError::Edit(edit)) => Err(PinError::Edit(edit)),
        Err(e @ PinLibraryError::Read(_)) => {
            Err(PinError::Lock(lock_failed(&e, input, version, "", None)))
        }
        Err(e) => Err(PinError::ByHand(format!(
            "{e}\n{}\nNext: make that change, then run `{} --to {}` again.",
            remains(current),
            input_command(input),
            version.release()
        ))),
    }
}

/// Return the message for a Nix command that failed while Kix moved the
/// input `input` to `version`, followed by `restored` and the next step.
fn lock_failed(
    error: &PinLibraryError,
    input: &str,
    version: &Version,
    restored: &str,
    tag: Option<&str>,
) -> String {
    let lines: Vec<String> = match error.nix_output() {
        // Nix prints its command line and a trace before the one line
        // that says what went wrong.
        Some(output) => super::out::excerpt(output),
        None => vec![error.to_string()],
    };
    let detail: String = lines.iter().map(|l| format!("  {l}\n")).collect();
    let release = version.release();
    let head = match tag {
        Some(tag) => format!("Cannot lock Kix library tag {tag} for Kix {release}:\n{detail}\n"),
        None => format!("Cannot read the inputs of flake.nix:\n{detail}\n"),
    };
    let command = input_command(input);
    let next = match tag {
        Some(tag) => format!(
            "Next: check that tag {tag} is reachable in your Kix input repository, then run `{command}` again."
        ),
        None => format!("Next: fix the error above, then run `{command}` again."),
    };
    format!("{head}{restored}{next}")
}

/// Pin the input `input`, now pinned to `current`, to `version` as `plan` says.
/// Return the name of each file Kix changed. When pinning fails, Kix puts
/// `flake.nix` and `flake.lock` back.
pub fn pin(
    input: &str,
    current: Option<&Version>,
    version: &Version,
    plan: &Plan,
) -> Result<Vec<&'static str>, PinError> {
    plan.apply().map_err(|e| {
        let restored = match current {
            Some(v) => format!(
                "Restored flake.nix and flake.lock to Kix {}.\n",
                v.release()
            ),
            None => "Restored flake.nix and flake.lock.\n".to_string(),
        };
        match e {
            PinLibraryError::Lock { .. } => PinError::Lock(lock_failed(
                &e,
                input,
                version,
                &restored,
                Some(&format!("v{}", version.release())),
            )),
            // The check says itself that Kix put the files back.
            e => PinError::ByHand(format!(
                "{e}\nNext: make that change, then run `{}` again.",
                input_command(input)
            )),
        }
    })
}

/// Return the text of the stop for an edit a person must make in
/// `flake.nix`. `state` says what Kix left as it was, and `command` runs
/// after the edit.
pub(super) fn edit_message(
    edit: &kix::pin_library::HandEdit,
    state: &str,
    command: &str,
) -> String {
    let count = match edit.lines.len() {
        2 => "two".to_string(),
        3 => "three".to_string(),
        n => n.to_string(),
    };
    let mut text = format!(
        "Cannot update flake.nix automatically: {count} inputs use the Kix library's repository:\n"
    );
    for (n, line) in &edit.lines {
        text.push_str(&format!("  flake.nix:{n}:   {line}\n"));
    }
    text.push('\n');
    text.push_str(state);
    text.push('\n');
    text.push_str(&format!(
        "Next: change the url of the Kix library input to {} in flake.nix, leave the\nother inputs as they are, then run `{command}` again.",
        edit.to_url
    ));
    text
}
