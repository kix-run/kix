use std::borrow::Cow;
use std::sync::OnceLock;

use owo_colors::OwoColorize;

use miette::IntoDiagnostic;

use crate::cli::{GlobalArgs, OutputFormat};

static COLOR_ENABLED: OnceLock<bool> = OnceLock::new();

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

/// Render a CommandResponse based on the output format.
///
/// `Markdown` is not a generic `CommandResponse` format — only specific commands
/// (currently `kix diff`) implement it. For other commands we fall back to
/// `Text` so the flag remains a no-op rather than an error.
pub fn render(response: &dyn CommandResponse, format: OutputFormat) -> miette::Result<String> {
    match format {
        OutputFormat::Text | OutputFormat::Markdown => Ok(response.format_text()),
        OutputFormat::Json => serde_json::to_string_pretty(&response.as_json()).into_diagnostic(),
        OutputFormat::Yaml => serde_yml::to_string(&response.as_json()).into_diagnostic(),
    }
}
