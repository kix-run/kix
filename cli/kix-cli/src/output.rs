use std::borrow::Cow;
use std::sync::OnceLock;

use owo_colors::OwoColorize;

use miette::IntoDiagnostic;

use crate::cli::{GlobalArgs, OutputFormat};

pub use kix::text::printable;

static COLOR_ENABLED: OnceLock<bool> = OnceLock::new();

/// How this run prints. `main` sets it once with [`init`], before the
/// command runs.
///
/// Where a command prints what:
/// - its answer goes to stdout: [`result`], or `println!` for text;
/// - warnings and errors go to stderr with `eprintln!`, even under `-q`;
/// - progress goes through [`say!`](crate::say) or
///   [`esay!`](crate::esay), which `-q` silences.
#[derive(Debug, Clone, Copy)]
pub struct Mode {
    /// `-q`.
    pub quiet: bool,
    /// `-o`, or the command's default when it is not given.
    pub format: OutputFormat,
    /// Stdout carries a machine-readable document that the progress lines
    /// [`say!`](crate::say) and [`progress_text`] print must not interleave
    /// with, so they go to stderr.
    pub progress_on_stderr: bool,
}

static MODE: OnceLock<Mode> = OnceLock::new();

/// Set this run's [`Mode`].
pub fn init(mode: Mode) {
    MODE.get_or_init(|| mode);
}

/// This run's [`Mode`]. Before [`init`], the defaults: not quiet, text,
/// progress on stdout.
fn mode() -> Mode {
    MODE.get().copied().unwrap_or(Mode {
        quiet: false,
        format: OutputFormat::Text,
        progress_on_stderr: false,
    })
}

/// Whether `-q` is set.
pub fn quiet() -> bool {
    mode().quiet
}

/// The output format: `-o`, or the command's default.
pub fn format() -> OutputFormat {
    mode().format
}

/// Whether [`say!`](crate::say) prints to stderr.
pub fn progress_on_stderr() -> bool {
    mode().progress_on_stderr
}

/// `println!` for progress lines. `-q` silences them, and they go to stderr
/// when stdout carries a document (`kix plan -o markdown`).
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

/// `print!` for text printed on the way to the answer, such as the plan a
/// deploy shows before it asks: stdout, or stderr when stdout carries a
/// machine-readable document. Unlike [`say!`](crate::say), `-q` does not
/// silence it.
pub fn progress_text(text: &str) {
    if progress_on_stderr() {
        eprint!("{text}");
    } else {
        print!("{text}");
    }
}

/// A spinner on stderr showing `msg`. `None` under `-q`, or when stderr is
/// not a terminal.
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

/// `eprintln!` for progress lines: `-q` silences them.
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

/// Whether colored output is enabled.
///
/// Returns false if `init_color()` hasn't been called yet (e.g. during early
/// startup errors). In normal operation, `main()` calls `init_color()` before
/// any code path reaches here.
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

/// A suffix for sweep summaries naming the resource types this account
/// may not list. Empty when there are none, so it can be appended blindly.
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

/// All command outputs must implement this trait.
/// Ensures every command supports both human-readable and structured output.
pub trait CommandResponse {
    /// Human-readable formatted output.
    fn format_text(&self) -> String;
    /// Machine-readable JSON value.
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
        OutputFormat::Yaml => serde_yml::to_string(&response.as_json()).into_diagnostic()?,
    };
    println!("{rendered}");
    Ok(())
}
