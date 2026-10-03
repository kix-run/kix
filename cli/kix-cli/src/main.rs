mod cli;
mod commands;
mod output;
mod plan;
pub mod trace_sink;

use clap::FromArgMatches;
use cli::{Cli, Command};

/// Validate cluster name format.
///
/// SECURITY: This is the primary defense against Nix expression injection.
/// The cluster name is interpolated into Nix eval strings in kix-eval's FFI layer.
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

/// The tracing filter for the verbosity flags, when `KIX_LOG` is unset.
///
/// Without `-v`, `kube_client::client` is held to errors. It logs a warning
/// with the body of every error response that is not JSON, such as the
/// plain-text `404 page not found` a group version answers while discovery
/// settles, and then returns the error, which kix reports or retries itself.
/// The same setting hides its other warnings: the `timeout in poll` and
/// `eof in poll` lines a watch stream logs before it ends, and the warning
/// on a response that fails to deserialize, which prints the whole response
/// body. `-vvv` (`debug` everywhere) or `KIX_LOG` shows them again.
/// `kube_client::client::tls` keeps its warning that certificate checks are
/// off.
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

fn main() -> miette::Result<()> {
    miette::set_hook(Box::new(|_| {
        Box::new(miette::MietteHandlerOpts::new().build())
    }))?;

    let cli = Cli::from_arg_matches(&cli::command().get_matches()).unwrap_or_else(|e| e.exit());
    init_tracing(cli.global.verbose, cli.global.quiet);
    output::init_color(&cli.global);

    // Completions doesn't need a CommandContext (no evaluator, no runtime)
    if let Command::Completions(args) = &cli.command {
        return commands::completions::run(args, &cli.global);
    }

    // `kix pin` reads and writes a file. It takes no flake and evaluates no
    // cluster on purpose: the state in which a pin most needs fixing is the
    // state in which evaluation is unhappy about it.
    if let Command::Pin(command) = &cli.command {
        return commands::pin::run(command, &cli.global);
    }

    // Drift uses only the cluster: no flake or Nix backend is needed, and
    // it must work from a bare kubeconfig outside any kix repo.
    if let Command::Drift(args) = &cli.command {
        return commands::drift::run(args, &cli.global);
    }

    // Validate cluster names before initializing the Nix backend (which is slow).
    if let Some(name) = cli.command.cluster_name() {
        validate_cluster_name(name)?;
    }

    let mut ctx = commands::CommandContext::new(&cli.global)?;

    match &cli.command {
        Command::Build(args) => commands::build::run(args, &mut ctx),
        Command::Diff(args) => commands::diff::run(args, &mut ctx),
        Command::Plan(args) => commands::plan::run(args, &mut ctx),
        Command::Check(args) => commands::check::run(args, &mut ctx),
        Command::Deploy(args) => commands::deploy::run(args, &mut ctx),
        Command::Status(args) => commands::status::run(args, &mut ctx),
        Command::List(args) => commands::list::run(args, &mut ctx),
        Command::Graph(args) => commands::graph::run(args, &mut ctx),
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
        Command::Completions(_) | Command::Drift(_) | Command::Pin(_) => unreachable!(),
    }
}

#[cfg(test)]
mod tracing_filter_tests {
    use super::default_filter;
    use std::sync::{Arc, Mutex};

    /// The lines the default filter lets through for `emit`.
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
