//! Acknowledge data migrations, and refuse a deploy while one is not
//! acknowledged.

use std::path::Path;

use miette::{Result, miette};

use super::halt::{Flow, refused};
use super::out;
use super::state::UpgradeState;
use crate::exit::{Exit, Stopped};

/// Add `refs` to the acknowledged data changes in `kix-upgrade.json`.
pub(super) fn acknowledge(dir: &Path, refs: &[String]) -> Flow<()> {
    let Some(mut state) = UpgradeState::read(dir).map_err(|e| miette!("{e}"))? else {
        return Err(refused(format!(
            "No kix-upgrade.json found in {}; nothing to acknowledge.",
            dir.display()
        )));
    };
    let mut wanted = Vec::new();
    for r in refs {
        let id = kix::changes::normalize_id(r).unwrap_or_else(|| r.clone());
        if !state.data_changes.iter().any(|d| d.reference == id) {
            let pending: Vec<&str> = state
                .unacknowledged()
                .iter()
                .map(|d| d.reference.as_str())
                .collect();
            return Err(refused(if pending.is_empty() {
                format!(
                    "`{r}` is not a pending data migration in kix-upgrade.json (no pending data migrations)."
                )
            } else {
                format!(
                    "`{r}` is not a pending data migration in kix-upgrade.json (pending: {}).",
                    out::list(&pending)
                )
            }));
        }
        wanted.push(id);
    }
    for id in &wanted {
        if !state.acknowledged.contains(id) {
            state.acknowledged.push(id.clone());
        }
    }
    state.write(dir).map_err(|e| miette!("{e}"))?;
    let acked = out::list(&wanted);
    let remaining: Vec<&str> = state
        .unacknowledged()
        .iter()
        .map(|d| d.reference.as_str())
        .collect();
    match remaining.len() {
        0 => println!("Acknowledged {acked} in kix-upgrade.json. You can now run `kix deploy`."),
        1 => println!(
            "Acknowledged {acked} in kix-upgrade.json. 1 data migration still requires `--acknowledge` before `kix deploy`: {}.",
            remaining[0]
        ),
        n => println!(
            "Acknowledged {acked} in kix-upgrade.json. {n} data migrations still require `--acknowledge` before `kix deploy`: {}.",
            out::list(&remaining)
        ),
    }
    Ok(())
}

/// Refuse a deploy while `kix-upgrade.json` in `dir` lists a change to
/// stored data that no one has acknowledged.
pub fn check_deploy(dir: &Path) -> Result<()> {
    let Some(state) = UpgradeState::read(dir).map_err(|e| miette!("{e}"))? else {
        return Ok(());
    };
    let open = state.unacknowledged();
    if open.is_empty() {
        return Ok(());
    }
    let one = open.len() == 1;
    let mut text = format!(
        "Deploy blocked: upgrade to Kix {} includes {}.\nNo clusters were contacted.\n",
        state.to,
        if one {
            "an unacknowledged data migration"
        } else {
            "unacknowledged data migrations"
        }
    );
    for d in &open {
        text.push('\n');
        text.push_str(&format!(
            "  [{}] ({}, moves stored data):\n",
            d.reference, d.release
        ));
        for line in out::wrap("    ", 4, &d.body) {
            text.push_str(&format!("{line}\n"));
        }
    }
    let refs: Vec<&str> = open.iter().map(|d| d.reference.as_str()).collect();
    text.push_str(&format!(
        "\nNext: once you are ready for {}, run:\n  kix upgrade --acknowledge {}\nThen run `kix deploy` again.",
        if one {
            "this migration"
        } else {
            "these migrations"
        },
        refs.join(" ")
    ));
    eprintln!("{text}");
    Err(Stopped(Exit::Failure).into())
}
