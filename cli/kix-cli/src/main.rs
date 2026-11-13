mod cli;
#[cfg(test)]
mod cli_surface;
mod client;
mod commands;
mod dispatch;
mod exit;
mod output;
mod plan;
mod plugin;
mod removed;
#[cfg(test)]
mod schemas;
mod select;
pub mod trace_sink;

use clap::FromArgMatches;
use cli::{Cli, Command, OutputFormat};
use exit::Exit;

/// Return the default tracing filter for the given verbosity when `KIX_LOG` is unset.
///
/// At default verbosity (`verbose == 0`), `kube_client::client` is restricted
/// to `error` to suppress noisy warnings that Kix already handles or retries:
/// non-JSON error responses (such as plain-text 404 responses during API
/// discovery), watch stream `timeout in poll` / `eof in poll` warnings, and
/// deserialization failure dumps. Pass `-vvv` or set `KIX_LOG` to see them.
/// `kube_client::client::tls` remains at `warn` so disabled certificate checks
/// are always surfaced.
fn default_filter(verbose: u8, quiet: bool) -> &'static str {
    if quiet {
        return "error";
    }
    match verbose {
        // kube_client logs every failed request as an error, including the
        // ones Kix retries and then reports itself.
        0 => "warn,kube_client::client=off,kube_client::client::tls=warn",
        1 => "kix=info",
        2 => "kix=debug",
        _ => "debug",
    }
}

/// Initialize tracing subscriber based on verbosity flags.
///
/// KIX_LOG env var overrides the verbose-derived filter (like RUST_LOG).
fn init_tracing(verbose: u8, quiet: bool) {
    use tracing_subscriber::EnvFilter;

    let custom = std::env::var("KIX_LOG").ok();
    // Without -v or KIX_LOG, only warnings show, so drop the timestamp and
    // module path that are there for debugging.
    let plain = custom.is_none() && verbose == 0;
    let filter = custom
        .map(EnvFilter::new)
        .unwrap_or_else(|| EnvFilter::new(default_filter(verbose, quiet)));

    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(trace_sink::make_writer)
        .with_ansi(false);
    if plain {
        builder.without_time().with_target(false).init();
    } else {
        builder
            .with_timer(tracing_subscriber::fmt::time::uptime())
            .init();
    }
}

/// Compute the [`output::Mode`] for `cli`.
fn output_mode(cli: &Cli) -> output::Mode {
    let default = cli
        .command
        .formats()
        .and_then(|formats| formats.first().copied())
        .unwrap_or(OutputFormat::Text);
    let format = cli.global.output.unwrap_or(default);
    // Route progress output to stderr when stdout carries a structured plan
    // document or JSON deploy log.
    let document = match &cli.command {
        Command::Plan(_) => format != OutputFormat::Text,
        Command::Deploy(args) if args.dry_run => format != OutputFormat::Text,
        Command::Deploy(args) => !args.operator && args.log_format == cli::LogFormat::Json,
        _ => false,
    };
    output::Mode {
        quiet: cli.global.quiet,
        format,
        progress_on_stderr: document,
    }
}

/// Refuse an `-o` format the command does not print.
fn check_format(cli: &Cli, matches: &clap::ArgMatches) -> miette::Result<()> {
    let (Some(asked), Some(formats)) = (cli.global.output, cli.command.formats()) else {
        return Ok(());
    };
    if formats.contains(&asked) {
        return Ok(());
    }
    // A global flag's value is found on the deepest subcommand.
    let mut words = vec!["kix"];
    let mut leaf = matches;
    while let Some((name, sub)) = leaf.subcommand() {
        words.push(name);
        leaf = sub;
    }
    let from_env = leaf.value_source("output") == Some(clap::parser::ValueSource::EnvVariable);
    Err(output::unsupported_format(
        &(words.join(" ") + cli.command.format_flags()),
        asked,
        formats,
        from_env,
        cli.command.format_hint().as_deref(),
    ))
}

/// Populate `global.override_input` from `KIX_OVERRIDE_INPUT` when
/// `--override-input` is not passed on the command line.
///
/// Handled outside clap because configuring a space delimiter on the argument
/// would also split `--override-input` flag values containing spaces (such as
/// `path:` URLs).
fn override_input_from_env(global: &mut cli::GlobalArgs) -> miette::Result<()> {
    if !global.override_input.is_empty() {
        return Ok(());
    }
    let Some(var) = std::env::var_os("KIX_OVERRIDE_INPUT") else {
        return Ok(());
    };
    let words: Vec<String> = var
        .to_str()
        .ok_or_else(|| miette::miette!("KIX_OVERRIDE_INPUT is not UTF-8"))?
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    if !words.len().is_multiple_of(2) {
        return Err(miette::miette!(
            "KIX_OVERRIDE_INPUT must hold pairs of an input name and a URL, separated by spaces"
        ));
    }
    global.override_input = words;
    Ok(())
}

fn main() -> miette::Result<()> {
    let exit = match run() {
        Ok(exit) => exit,
        Err(report) => match exit::stopped(&report) {
            Some(exit) => exit,
            None => return Err(report),
        },
    };
    if exit != Exit::Success {
        use std::io::Write;
        let _ = std::io::stdout().flush();
        #[allow(clippy::disallowed_methods)]
        std::process::exit(exit.code());
    }
    Ok(())
}

/// Parse the command line and run the command, returning how `kix` ends.
fn run() -> miette::Result<Exit> {
    // Wrapping helps only a person reading a terminal. In a log or a pipe, a
    // line break can fall inside a path or a command, which breaks searching
    // and copying, and makes the text depend on how long its paths are.
    miette::set_hook(Box::new(|_| {
        let wrap = std::io::IsTerminal::is_terminal(&std::io::stderr());
        Box::new(miette::MietteHandlerOpts::new().wrap_lines(wrap).build())
    }))?;

    // Run the version of Kix the project names before clap parses, since that
    // version may take other arguments.
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if select::run(&args)? == select::Outcome::PrintedVersion {
        return Ok(Exit::Success);
    }

    let matches = match cli::command().try_get_matches_from(&args) {
        Ok(matches) => matches,
        Err(e) => return Ok(exit::clap_error(&e)),
    };
    if let Some(removed) = removed::find(&matches, removed::COMMANDS, removed::FLAGS) {
        return Ok(removed.refuse());
    }
    let mut cli = match Cli::from_arg_matches(&matches) {
        Ok(cli) => cli,
        Err(e) => return Ok(exit::clap_error(&e)),
    };
    if let Some(removed) = removed::refused(&cli.command) {
        return Ok(removed.refuse());
    }
    override_input_from_env(&mut cli.global)?;
    check_format(&cli, &matches)?;
    init_tracing(cli.global.verbose, cli.global.quiet);
    output::init_color(&cli.global);
    output::init(output_mode(&cli));
    dispatch::run(&cli)
}

#[cfg(test)]
mod tracing_filter_tests {
    use super::default_filter;
    use std::sync::{Arc, Mutex};

    /// Capture the log output emitted by `emit` under the default tracing filter.
    fn logged(emit: impl FnOnce()) -> String {
        let buf = Arc::new(Mutex::new(Vec::<u8>::new()));
        let sink = buf.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new(default_filter(0, false)))
            .with_writer(move || Sink(sink.clone()))
            .with_ansi(false)
            .finish();
        tracing::subscriber::with_default(subscriber, emit);
        String::from_utf8(buf.lock().unwrap().clone()).unwrap()
    }

    struct Sink(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for Sink {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn the_default_filter_drops_kube_client_error_body_warnings() {
        let out = logged(|| {
            tracing::warn!(target: "kube_client::client", "Unsuccessful data error parse: 404 page not found");
            tracing::warn!(target: "kube_client::client::tls", "Server cert bypassed");
            tracing::warn!(target: "kube_client::config", "impersonating user");
            tracing::warn!(target: "kix::cluster", "a kix warning");
            tracing::error!(target: "kube_client::client::builder", "failed with status 500 Internal Server Error");
        });
        assert!(!out.contains("status 500"), "{out}");
        assert!(!out.contains("404 page not found"), "{out}");
        assert!(out.contains("Server cert bypassed"), "{out}");
        assert!(out.contains("impersonating user"), "{out}");
        assert!(out.contains("a kix warning"), "{out}");
    }
}

#[cfg(test)]
mod output_mode_tests {
    use super::*;

    fn mode(args: &[&str]) -> output::Mode {
        let matches = cli::command().get_matches_from(args);
        output_mode(&Cli::from_arg_matches(&matches).unwrap())
    }

    /// Only a document on stdout sends the progress before it to stderr: a
    /// plan from `kix plan` and `kix deploy --dry-run` with `-o` other than
    /// text, and the deploy log.
    #[test]
    fn progress_goes_to_stderr_only_beside_a_document() {
        assert!(mode(&["kix", "plan", "c", "-o", "json"]).progress_on_stderr);
        assert!(mode(&["kix", "plan", "c", "-o", "markdown"]).progress_on_stderr);
        assert!(!mode(&["kix", "plan", "c"]).progress_on_stderr);
        assert!(mode(&["kix", "deploy", "c", "--dry-run", "-o", "yaml"]).progress_on_stderr);
        assert!(!mode(&["kix", "deploy", "c", "-o", "json"]).progress_on_stderr);
        assert!(!mode(&["kix", "status", "c", "-o", "json"]).progress_on_stderr);
        assert!(mode(&["kix", "deploy", "c", "--log-format", "json"]).progress_on_stderr);
        assert!(!mode(&["kix", "deploy", "c", "--log-format", "line"]).progress_on_stderr);
        assert!(
            !mode(&["kix", "deploy", "c", "--operator", "--log-format", "json"]).progress_on_stderr
        );
    }

    #[test]
    fn each_command_has_its_default_format() {
        assert_eq!(mode(&["kix", "build", "c"]).format, OutputFormat::Yaml);
        assert_eq!(
            mode(&["kix", "compliance", "sbom", "c"]).format,
            OutputFormat::Json
        );
        assert_eq!(
            mode(&["kix", "compliance", "attest", "c"]).format,
            OutputFormat::Json
        );
        assert_eq!(
            mode(&["kix", "list", "clusters"]).format,
            OutputFormat::Text
        );
        assert_eq!(
            mode(&["kix", "build", "c", "-o", "json"]).format,
            OutputFormat::Json
        );
    }

    #[test]
    fn quiet_is_the_flag() {
        assert!(mode(&["kix", "-q", "gc", "c"]).quiet);
        assert!(!mode(&["kix", "gc", "c"]).quiet);
    }
}
