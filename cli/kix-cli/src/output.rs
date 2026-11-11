use std::borrow::Cow;
use std::sync::OnceLock;

use owo_colors::OwoColorize;

use miette::IntoDiagnostic;

use crate::cli::{GlobalArgs, OutputFormat};

pub use kix::text::printable;

static COLOR_ENABLED: OnceLock<bool> = OnceLock::new();

/// Output routing configuration initialized once by `main` via [`init`].
///
/// Output streams:
/// - Command results go to stdout via [`result`] or `println!`.
/// - Warnings and errors go to stderr via `eprintln!`, even under `-q`.
/// - Progress messages go through [`say!`](crate::say) or
///   [`esay!`](crate::esay) and are suppressed by `-q`.
#[derive(Debug, Clone, Copy)]
pub struct Mode {
    /// Suppress progress output (`-q`).
    pub quiet: bool,
    /// Output format from `-o`, or the command's default format.
    pub format: OutputFormat,
    /// Route [`say!`](crate::say) and [`progress_text`] to stderr so progress
    /// output does not corrupt a machine-readable document on stdout.
    pub progress_on_stderr: bool,
}

static MODE: OnceLock<Mode> = OnceLock::new();

/// Set this run's [`Mode`].
pub fn init(mode: Mode) {
    MODE.get_or_init(|| mode);
}

/// Return the current [`Mode`], or the default text mode if [`init`] has not
/// been called.
fn mode() -> Mode {
    MODE.get().copied().unwrap_or(Mode {
        quiet: false,
        format: OutputFormat::Text,
        progress_on_stderr: false,
    })
}

/// Return whether `--quiet` (`-q`) is enabled.
pub fn quiet() -> bool {
    mode().quiet
}

/// Return the active [`OutputFormat`].
pub fn format() -> OutputFormat {
    mode().format
}

/// Return whether [`say!`](crate::say) routes progress lines to stderr.
pub fn progress_on_stderr() -> bool {
    mode().progress_on_stderr
}

/// Print a progress line to stdout (or stderr when stdout carries a structured
/// document), unless `-q` is set.
#[macro_export]
macro_rules! say {
    ($($arg:tt)*) => {
        if !$crate::output::quiet() {
            if $crate::output::progress_on_stderr() {
                eprintln!($($arg)*);
            } else {
                println!($($arg)*);
            }
        }
    };
}

/// Print intermediate progress text (such as the pre-deploy plan preview) to
/// stdout, or to stderr when stdout carries a machine-readable document.
/// Unlike [`say!`](crate::say), this is not suppressed by `-q`.
pub fn progress_text(text: &str) {
    if progress_on_stderr() {
        eprint!("{text}");
    } else {
        print!("{text}");
    }
}

/// Create a stderr spinner displaying `msg`, or return `None` when `-q` is set
/// or stderr is not a terminal.
pub fn spinner(msg: impl Into<Cow<'static, str>>) -> Option<indicatif::ProgressBar> {
    use std::io::IsTerminal;
    if std::io::stderr().is_terminal() && !quiet() {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(msg);
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    }
}

/// Print a progress line to stderr unless `-q` is set.
#[macro_export]
macro_rules! esay {
    ($($arg:tt)*) => {
        if !$crate::output::quiet() {
            eprintln!($($arg)*);
        }
    };
}

/// Initialize color support based on CLI flags and environment.
pub fn init_color(global: &GlobalArgs) {
    COLOR_ENABLED.get_or_init(|| {
        if global.no_color {
            return false;
        }
        // NO_COLOR spec (no-color.org): disable when set to any value
        if std::env::var_os("NO_COLOR").is_some() {
            return false;
        }
        if std::env::var("TERM").is_ok_and(|t| t == "dumb") {
            return false;
        }
        use std::io::IsTerminal;
        std::io::stdout().is_terminal()
    });
}

/// Return whether colored output is enabled.
///
/// Returns `false` if [`init_color`] has not been called yet (for example,
/// during early startup errors).
pub fn color_enabled() -> bool {
    *COLOR_ENABLED.get().unwrap_or(&false)
}

pub fn green(s: &str) -> Cow<'_, str> {
    if color_enabled() {
        Cow::Owned(format!("{}", s.green()))
    } else {
        Cow::Borrowed(s)
    }
}

pub fn red(s: &str) -> Cow<'_, str> {
    if color_enabled() {
        Cow::Owned(format!("{}", s.red()))
    } else {
        Cow::Borrowed(s)
    }
}

pub fn yellow(s: &str) -> Cow<'_, str> {
    if color_enabled() {
        Cow::Owned(format!("{}", s.yellow()))
    } else {
        Cow::Borrowed(s)
    }
}

pub fn dim(s: &str) -> Cow<'_, str> {
    if color_enabled() {
        Cow::Owned(format!("{}", s.dimmed()))
    } else {
        Cow::Borrowed(s)
    }
}

pub fn bold(s: &str) -> Cow<'_, str> {
    if color_enabled() {
        Cow::Owned(format!("{}", s.bold()))
    } else {
        Cow::Borrowed(s)
    }
}

/// Format a summary suffix listing resource types that the current account
/// cannot list, or return an empty string if there are none.
pub fn forbidden_note(forbidden: &[String]) -> String {
    if forbidden.is_empty() {
        return String::new();
    }
    format!(
        "; {} not listable with this account: {}",
        forbidden.len(),
        forbidden.join(", ")
    )
}

/// Check if the terminal is interactive (for confirmation prompts).
/// Returns false in CI or when piped. Respects KIX_NO_INTERACTIVE env var.
pub fn is_interactive() -> bool {
    use std::io::IsTerminal;
    std::env::var_os("KIX_NO_INTERACTIVE").is_none() && std::io::stdin().is_terminal()
}

/// What a command was about to do when it stopped for want of a confirmation,
/// for [`refuse_unconfirmed`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unconfirmed {
    Deploy,
    Rollback,
    GarbageCollect,
    MigrateDomain,
}

impl Unconfirmed {
    /// Return the opening sentence, the sentence that says nothing changed,
    /// and what `--yes` lets the command do.
    fn wording(self, cluster: &str) -> (String, &'static str, &'static str) {
        match self {
            Unconfirmed::Deploy => (
                format!("Deploy of '{cluster}' aborted"),
                "Nothing was applied to the cluster.",
                "apply",
            ),
            Unconfirmed::Rollback => (
                format!("Rollback of '{cluster}' aborted"),
                "Nothing was applied to the cluster.",
                "roll back",
            ),
            Unconfirmed::GarbageCollect => (
                format!("Garbage collection of '{cluster}' aborted"),
                "Nothing was deleted from the cluster.",
                "delete orphaned resources",
            ),
            Unconfirmed::MigrateDomain => (
                format!("Domain migration of '{cluster}' aborted"),
                "Nothing was changed on the cluster.",
                "migrate",
            ),
        }
    }
}

/// Stop with exit code 1 because the command needs a confirmation and stdin
/// is not a terminal. The message repeats the command line with `--yes`.
pub fn refuse_unconfirmed(what: Unconfirmed, cluster: &str) -> ! {
    let (headline, nothing, does) = what.wording(cluster);
    eprintln!(
        "{} {headline}: confirmation required in non-interactive mode.",
        red("x")
    );
    eprintln!("  {nothing}");
    eprintln!();
    eprintln!("  Next:");
    eprintln!("    Pass '--yes' ('-y') to {does} without prompting:");
    eprintln!("      {}", with_yes(std::env::args().skip(1)));
    std::process::exit(1);
}

/// Return the command line `kix <args> --yes`, quoting arguments that a
/// shell would split.
fn with_yes(args: impl Iterator<Item = String>) -> String {
    let mut words = vec!["kix".to_string()];
    for arg in args {
        if arg.is_empty() || arg.contains(|c: char| c.is_whitespace() || "'\"$`\\".contains(c)) {
            words.push(format!("'{}'", arg.replace('\'', r"'\''")));
        } else {
            words.push(arg);
        }
    }
    words.push("--yes".to_string());
    words.join(" ")
}

/// All command outputs must implement this trait.
/// Ensures every command supports both human-readable and structured output.
pub trait CommandResponse {
    /// Render human-readable text output.
    fn format_text(&self) -> String;
    /// Serialize the response as a JSON value.
    fn as_json(&self) -> serde_json::Value;
}

/// Print a command's answer to stdout in the output [`format()`].
///
/// `Markdown` is not a generic `CommandResponse` format. Only specific commands
/// (`kix plan`, `kix diff`) implement it. For other commands we fall back to
/// `Text` so the flag remains a no-op rather than an error.
pub fn result(response: &dyn CommandResponse) -> miette::Result<()> {
    let rendered = match format() {
        OutputFormat::Text | OutputFormat::Markdown => response.format_text(),
        OutputFormat::Json => {
            serde_json::to_string_pretty(&response.as_json()).into_diagnostic()?
        }
        OutputFormat::Yaml => kix::yaml::to_string(&response.as_json()).into_diagnostic()?,
    };
    println!("{rendered}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The suggested command keeps the user's arguments and quotes the ones
    /// a shell would split.
    #[test]
    fn the_suggested_command_repeats_the_arguments_with_yes() {
        let args = ["deploy", "prod", "--context", "my ctx"].map(String::from);
        assert_eq!(
            with_yes(args.into_iter()),
            "kix deploy prod --context 'my ctx' --yes"
        );
    }
}
