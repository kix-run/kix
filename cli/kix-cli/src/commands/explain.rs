//! `kix explain <id>`: print the change record behind an id such as `K0001`,
//! and the hint after an error that names one.

use kix::changes::{self, Compiled};

use crate::output::{self, CommandResponse};

struct ExplainResponse {
    compiled: &'static Compiled,
}

impl CommandResponse for ExplainResponse {
    fn format_text(&self) -> String {
        render(self.compiled)
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(self.compiled).expect("a record serializes")
    }
}

pub fn run(id: &str) -> miette::Result<()> {
    let Some(normalized) = changes::normalize_id(id) else {
        return Err(miette::miette!(
            "'{id}' is not a change record id. An id is K and four digits, such as K0001."
        ));
    };
    match changes::find(&normalized) {
        Some(compiled) => output::result(&ExplainResponse { compiled }),
        None => Err(miette::miette!(
            "Kix {} has no change record {normalized}. Kix knows the records up to its own \
             version, so a newer Kix may know this id.",
            kix::VERSION
        )),
    }
}

/// Return the text `kix explain` prints for `compiled`.
fn render(compiled: &Compiled) -> String {
    let r = &compiled.record;
    let mut lines = Vec::new();
    let title = match &r.id {
        Some(id) => format!("{id}: {}", r.kind.heading()),
        None => r.kind.heading().to_owned(),
    };
    lines.push(output::bold(&title).into_owned());
    lines.push(match &compiled.release {
        Some(v) => format!("Released in Kix {v}"),
        None => "Not released yet".to_owned(),
    });
    for (label, items) in [
        ("Packages", &r.packages),
        ("Library", &r.library),
        ("CLI", &r.cli),
        ("CVE", &r.cve),
    ] {
        if !items.is_empty() {
            lines.push(format!("{label}: {}", items.join(", ")));
        }
    }
    if r.state {
        lines.push("Changes the state Kix keeps in the cluster".to_owned());
    }
    if r.touches_data {
        lines.push("Moves or reinterprets stored data".to_owned());
    }
    if r.required_stop {
        lines.push(
            "Required stop: deploy every cluster with this release before upgrading further"
                .to_owned(),
        );
    }
    if let Some(w) = &r.workaround {
        lines.push(format!("Workaround: {}", w.trim()));
    }
    lines.push(String::new());
    lines.push(r.body.trim().to_owned());
    lines.join("\n")
}

/// Return the line to print after an error whose text names an id that
/// `find` knows, or `None`.
pub fn hint<'a>(error: &str, find: impl Fn(&str) -> Option<&'a Compiled>) -> Option<String> {
    changes::ids_in(error)
        .into_iter()
        .find(|id| find(id).is_some())
        .map(|id| format!("Run `kix explain {id}` for what changed and how to update."))
}

/// Print [`hint`] for the records built into this Kix on stderr, when
/// `error` names one.
pub fn print_hint(error: &str) {
    if let Some(line) = hint(error, changes::find) {
        eprintln!("{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::changes::{Record, find_in};

    fn fixture() -> Vec<Compiled> {
        vec![
            Compiled {
                release: Some("0.10.0".into()),
                record: Record::parse(
                    "rename-replica-count",
                    "+++\nkind = \"error\"\npackages = [\"echo-server\", \"dns-exporter\"]\nid = \"K0001\"\n+++\n`echo-server` renames `replicaCount` to `replicas`. Set `replicas` instead.\n",
                )
                .unwrap(),
            },
            Compiled {
                release: None,
                record: Record::parse(
                    "move-data",
                    "+++\nkind = \"silent\"\nstate = true\nrequired-stop = true\ntouches-data = true\nid = \"K0002\"\n+++\nMoves the data.\n",
                )
                .unwrap(),
            },
        ]
    }

    #[test]
    fn explain_prints_the_record() {
        let records = fixture();
        let text = render(find_in(&records, "[k0001]").unwrap());
        assert_eq!(
            text,
            "K0001: Breaking (shows an error)\n\
             Released in Kix 0.10.0\n\
             Packages: echo-server, dns-exporter\n\
             \n\
             `echo-server` renames `replicaCount` to `replicas`. Set `replicas` instead."
        );
        let text = render(find_in(&records, "K0002").unwrap());
        assert!(
            text.starts_with("K0002: Breaking (no error)\nNot released yet\n"),
            "{text}"
        );
        assert!(text.contains("Required stop"), "{text}");
        assert!(text.contains("stored data"), "{text}");
    }

    #[test]
    fn explain_hint_names_a_known_id() {
        let records = fixture();
        let find = |id: &str| find_in(&records, id);
        assert_eq!(
            hint(
                "failed to build cluster: [K0001] echo-server: set `replicas`",
                find
            )
            .as_deref(),
            Some("Run `kix explain K0001` for what changed and how to update.")
        );
        assert_eq!(
            hint("[K0099] unknown, then [K0002] known", find).as_deref(),
            Some("Run `kix explain K0002` for what changed and how to update.")
        );
        assert_eq!(hint("[K0099] not built in", find), None);
        assert_eq!(hint("K0001 without brackets", find), None);
    }
}
