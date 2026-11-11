//! The command-line surface a script can depend on, kept as a snapshot.
//!
//! One line for each visible command, and one for each of its visible
//! arguments: the long and short flag names, whether the argument takes a
//! value, whether it is required, and the possible values of an enum. A
//! positional argument appears by name. Descriptions are left out, so
//! rewording help text does not change the snapshot.
//!
//! `scripts/change-kind.py` reads the committed snapshot. A pull request that
//! removes or changes a line in it must add a change record that names the
//! command or flag in its `cli` field.
//!
//! Refresh it with `INSTA_UPDATE=always cargo test -p kix-cli cli_surface`.

fn argument(path: &str, arg: &clap::Arg) -> String {
    let mut line = path.to_string();
    if arg.is_positional() {
        line.push_str(&format!(" <{}>", arg.get_id()));
    } else {
        if let Some(long) = arg.get_long() {
            line.push_str(&format!(" --{long}"));
        }
        if let Some(short) = arg.get_short() {
            line.push_str(&format!(" -{short}"));
        }
        if arg.get_action().takes_values() {
            line.push_str(" <value>");
        }
    }
    if arg.is_required_set() {
        line.push_str(" required");
    }
    let values: Vec<String> = arg
        .get_possible_values()
        .iter()
        .filter(|v| !v.is_hide_set())
        .map(|v| v.get_name().to_string())
        .collect();
    if !values.is_empty() {
        line.push_str(&format!(" [{}]", values.join("|")));
    }
    line
}

fn render(cmd: &clap::Command, out: &mut Vec<String>) {
    if cmd.is_hide_set() {
        return;
    }
    let path = cmd.get_bin_name().unwrap_or(cmd.get_name());
    out.push(path.to_string());
    for arg in cmd.get_arguments() {
        let builtin = matches!(arg.get_id().as_str(), "help" | "version");
        if !arg.is_hide_set() && !builtin {
            out.push(argument(path, arg));
        }
    }
    for sub in cmd.get_subcommands() {
        if sub.get_name() != "help" {
            render(sub, out);
        }
    }
}

#[test]
fn cli_surface_of_every_command() {
    let mut cmd = crate::cli::command();
    cmd.build();
    let mut lines = Vec::new();
    render(&cmd, &mut lines);
    let out = lines.join("\n") + "\n";
    insta::with_settings!({
        snapshot_path => "../tests/snapshots",
        prepend_module_to_snapshot => false,
        omit_expression => true,
    }, {
        insta::assert_snapshot!("cli_surface", out);
    });
}
