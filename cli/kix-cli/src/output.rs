use std::sync::OnceLock;

use owo_colors::OwoColorize;

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
pub fn color_enabled() -> bool {
    *COLOR_ENABLED.get().unwrap_or(&false)
}

pub fn green(s: &str) -> String {
    if color_enabled() {
        format!("{}", s.green())
    } else {
        s.to_string()
    }
}

pub fn red(s: &str) -> String {
    if color_enabled() {
        format!("{}", s.red())
    } else {
        s.to_string()
    }
}

pub fn yellow(s: &str) -> String {
    if color_enabled() {
        format!("{}", s.yellow())
    } else {
        s.to_string()
    }
}

pub fn dim(s: &str) -> String {
    if color_enabled() {
        format!("{}", s.dimmed())
    } else {
        s.to_string()
    }
}

pub fn bold(s: &str) -> String {
    if color_enabled() {
        format!("{}", s.bold())
    } else {
        s.to_string()
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
pub fn render(response: &dyn CommandResponse, format: OutputFormat) -> String {
    match format {
        OutputFormat::Text => response.format_text(),
        OutputFormat::Json => serde_json::to_string_pretty(&response.as_json()).unwrap(),
        OutputFormat::Yaml => serde_yml::to_string(&response.as_json()).unwrap(),
    }
}
