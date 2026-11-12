mod cli;
#[cfg(test)]
mod cli_surface;
mod client;
mod commands;
mod output;
mod plan;
mod plugin;
#[cfg(test)]
mod schemas;
mod select;
pub mod trace_sink;

use clap::FromArgMatches;
use cli::{Cli, Command, OutputFormat};

/// Validate cluster name format.
///
/// SECURITY: This is the primary defense against Nix expression injection.
/// The cluster name is spliced into the flake attribute `nix eval` reads
/// (`kix::eval::nix`) and into the `--apply` expression of `nix eval`
/// (`cluster_name_command`).
/// Only alphanumeric characters, hyphens, and underscores are safe.
fn validate_cluster_name(name: &str) -> miette::Result<()> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err(miette::miette!(
            "'{}' is not a valid cluster name. Use a name like 'example' or 'nw1', not a file path.",
            name
        ));
    }
    Ok(())
}

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
        0 => "warn,kube_client::client=error,kube_client::client::tls=warn",
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

    let filter = std::env::var("KIX_LOG")
        .map(EnvFilter::new)
        .unwrap_or_else(|_| EnvFilter::new(default_filter(verbose, quiet)));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(trace_sink::make_writer)
        .with_timer(tracing_subscriber::fmt::time::uptime())
        .with_ansi(false)
        .init();
}

/// Compute the [`output::Mode`] for `cli`.
fn output_mode(cli: &Cli) -> output::Mode {
    let default = match &cli.command {
        Command::Build(_) => OutputFormat::Yaml,
        Command::Compliance(args) => match args.command {
            cli::ComplianceCommand::Sbom(_) | cli::ComplianceCommand::Attest(_) => {
                OutputFormat::Json
            }
            cli::ComplianceCommand::Audit(_) => OutputFormat::Text,
        },
        _ => OutputFormat::Text,
    };
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
        return Ok(());
    }

    let mut cli = Cli::from_arg_matches(&cli::command().get_matches()).unwrap_or_else(|e| e.exit());
    override_input_from_env(&mut cli.global)?;
    if let Command::Plugin(args) = &cli.command {
        return plugin::run(args, &cli.global);
    }
    init_tracing(cli.global.verbose, cli.global.quiet);
    output::init_color(&cli.global);
    output::init(output_mode(&cli));

    // Completions doesn't need a CommandContext (no evaluator, no runtime)
    if let Command::Completions(args) = &cli.command {
        return commands::completions::run(args, &cli.global);
    }

    if let Command::SelfCmd(command) = &cli.command {
        return commands::self_cmd::run(command);
    }

    // Doctor reports a broken runtime instead of stopping on it.
    if let Command::Doctor = &cli.command {
        return commands::doctor::run(&cli.global);
    }

    // `kix pin` operates directly on the pin file without evaluating the
    // flake, so it works even when evaluation fails.
    if let Command::Pin(command) = &cli.command {
        return commands::pin::run(command, &cli.global);
    }

    // `kix upgrade` runs every evaluation in the Kix version of each step,
    // so it needs no evaluator, and no runtime unless it moves flake.lock.
    if let Command::Upgrade(args) = &cli.command {
        return commands::upgrade::run(args, &cli.global);
    }

    // A deploy waits for a person to acknowledge each change to stored data
    // that the last `kix upgrade` found.
    if let Command::Deploy(args) = &cli.command
        && !args.dry_run
        && let Some(dir) = commands::project_dir(&cli.global.flake)
    {
        commands::upgrade::check_deploy(&dir)?;
    }

    // Drift uses only the cluster: no flake or Nix backend is needed, and
    // it must work from a bare kubeconfig outside any Kix repository.
    if let Command::Drift(args) = &cli.command {
        return commands::drift::run(args, &cli.global);
    }

    // `kix secret` reads only the SOPS file it is given, inside or outside a
    // project.
    if let Command::Secret(command) = &cli.command {
        return commands::secret::run(command);
    }

    // Validate cluster names before initializing the Nix backend (which is slow).
    if let Some(name) = cli.command.cluster_name() {
        validate_cluster_name(name)?;
    }

    // The project's builder decides which Nix every later step runs.
    commands::select_builder(&cli.global)?;

    // Stop before any work when Kix has no runtime, or its runtime comes from
    // another release.
    kix::runtime::runtime().map_err(|e| miette::miette!("{e}"))?;

    // `kix lib update` repairs flake.lock, so it needs no evaluator or eval
    // cache.
    if let Command::Lib(command) = &cli.command {
        return commands::library::run(command, &cli.global);
    }

    let mut ctx = commands::CommandContext::new(
        &cli.global,
        &commands::compliance::receipt::ComplianceReceipts,
    )?;

    match &cli.command {
        Command::Build(args) => commands::build::run(args, &mut ctx),
        Command::Diff(args) => commands::diff::run(args, &mut ctx),
        Command::Plan(args) => commands::plan::run(&args.plan, args.save.as_deref(), &mut ctx),
        Command::Check(args) => commands::check::run(args, &mut ctx),
        Command::Deploy(args) => commands::deploy::run(args, &mut ctx),
        Command::Status(args) => commands::status::run(args, &mut ctx),
        Command::List(args) => commands::list::run(args, &mut ctx),
        Command::Graph(args) => commands::graph::run(args, &mut ctx),
        Command::Bundle(args) => commands::bundle::run(args, &mut ctx),
        Command::Inspect(args) => commands::inspect::run(args, &mut ctx),
        Command::Gc(args) => commands::gc::run(args, &mut ctx),
        Command::Migrate(cli::MigrateCommand::Domain(args)) => {
            commands::migrate::run(args, &mut ctx)
        }
        Command::Rollback(args) => commands::rollback::run(args, &mut ctx),
        Command::Export(args) => commands::export::run(args, &mut ctx),
        Command::Logs(args) => commands::logs::run(args, &mut ctx),
        Command::Pf(args) => commands::pf::run(args, &mut ctx),
        Command::Health(args) => commands::health::run(args, &mut ctx),
        Command::Images(args) => commands::images::run(args, &mut ctx),
        Command::Snapshot(args) => commands::snapshot::run(args, &mut ctx),
        Command::Compliance(args) => commands::compliance::run(args, &mut ctx),
        Command::Completions(_)
        | Command::Doctor
        | Command::Drift(_)
        | Command::Pin(_)
        | Command::Lib(_)
        | Command::Secret(_)
        | Command::Upgrade(_)
        | Command::SelfCmd(_)
        | Command::Plugin(_) => unreachable!(),
    }
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
        });
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
