//! The help text of every `kix` command, kept as a snapshot.
//!
//! `scripts/change-kind.py` reads the committed snapshot. A pull request that
//! removes or rewords a line in it changes the CLI surface, and must add a
//! change record that names the command or flag in its `cli` field.
//!
//! Refresh it with `INSTA_UPDATE=always cargo test -p kix-cli cli_surface`.

/// Hide environment values so the snapshot does not depend on the shell.
fn without_env_values(cmd: clap::Command) -> clap::Command {
    cmd.mut_args(|a| a.hide_env_values(true))
        .mut_subcommands(without_env_values)
}

fn render(cmd: &clap::Command, out: &mut String) {
    if cmd.is_hide_set() {
        return;
    }
    let path = cmd.get_bin_name().unwrap_or(cmd.get_name());
    out.push_str(&format!("## {path}\n\n"));
    out.push_str(&cmd.clone().render_long_help().to_string());
    out.push('\n');
    for sub in cmd.get_subcommands() {
        if sub.get_name() != "help" {
            render(sub, out);
        }
    }
}

#[test]
fn cli_surface_help_of_every_command() {
    let mut cmd = without_env_values(crate::cli::command());
    cmd.build();
    let mut out = String::new();
    render(&cmd, &mut out);
    insta::with_settings!({
        snapshot_path => "../tests/snapshots",
        prepend_module_to_snapshot => false,
        omit_expression => true,
    }, {
        insta::assert_snapshot!("cli_surface_help", out);
    });
}
