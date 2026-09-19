use std::collections::BTreeMap;
use std::io::IsTerminal;

use miette::Result;
use serde::Serialize;

use crate::cli::{ImagesArgs, OutputFormat};
use crate::output::{self, CommandResponse};

use super::CommandContext;

/// A single container image reference found in the cluster manifests.
#[derive(Debug, Clone, Serialize, PartialEq, Eq, PartialOrd, Ord)]
struct ImageEntry {
    /// Full image reference (e.g. "quay.io/jetstack/cert-manager-controller:v1.17.1")
    image: String,
    /// Resources that reference this image
    sources: Vec<ImageSource>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, PartialOrd, Ord)]
struct ImageSource {
    kind: String,
    namespace: String,
    name: String,
    container: String,
}

struct ImagesResponse {
    images: Vec<ImageEntry>,
}

impl CommandResponse for ImagesResponse {
    fn format_text(&self) -> String {
        if self.images.is_empty() {
            return "No container images found.\n".to_string();
        }

        let mut out = String::new();
        for entry in &self.images {
            out.push_str(&entry.image);
            out.push('\n');
        }
        out
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(&self.images).unwrap_or_default()
    }
}

pub fn run(args: &ImagesArgs, ctx: &mut CommandContext) -> Result<()> {
    let spinner = if std::io::stderr().is_terminal() && !ctx.global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(format!("Evaluating cluster '{}'...", args.cluster));
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    };

    let cluster_output = ctx.eval_cluster_or_suggest(&args.cluster);

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    let cluster_output = cluster_output?;

    // Collect images: image_ref -> Vec<source>
    let mut image_map: BTreeMap<String, Vec<ImageSource>> = BTreeMap::new();

    for manifest in &cluster_output.raw_manifests {
        let kind = manifest
            .pointer("/kind")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let name = manifest
            .pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let namespace = manifest
            .pointer("/metadata/namespace")
            .and_then(|v| v.as_str())
            .unwrap_or("_cluster");

        if let Some(pod_spec) = kix::manifest::workload::pod_spec(manifest) {
            // Extract from containers, initContainers, and ephemeralContainers
            for field in ["containers", "initContainers", "ephemeralContainers"] {
                if let Some(containers) = pod_spec.get(field).and_then(|v| v.as_array()) {
                    for container in containers {
                        if let Some(image) = container.get("image").and_then(|v| v.as_str()) {
                            let container_name = container
                                .get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or("<unnamed>");
                            image_map
                                .entry(image.to_string())
                                .or_default()
                                .push(ImageSource {
                                    kind: kind.to_string(),
                                    namespace: namespace.to_string(),
                                    name: name.to_string(),
                                    container: container_name.to_string(),
                                });
                        }
                    }
                }
            }
        }
    }

    // Merge extra images declared by packages (operator-spawned images)
    if let Some(extra) = &cluster_output.extra_images {
        for ei in extra {
            image_map
                .entry(ei.image.clone())
                .or_default()
                .push(ImageSource {
                    kind: ei.source.kind.clone(),
                    namespace: ei.source.namespace.clone(),
                    name: ei.source.name.clone(),
                    container: ei.source.container.clone(),
                });
        }
    }

    let images: Vec<ImageEntry> = image_map
        .into_iter()
        .map(|(image, sources)| ImageEntry { image, sources })
        .collect();

    let response = ImagesResponse { images };

    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Text | OutputFormat::Markdown => {
            if args.sources {
                // Verbose text: show sources per image
                for entry in &response.images {
                    println!("{}", entry.image);
                    for src in &entry.sources {
                        println!(
                            "  {} {}/{} (container: {})",
                            src.kind, src.namespace, src.name, src.container
                        );
                    }
                }
            } else {
                print!("{}", response.format_text());
            }
        }
        OutputFormat::Json => {
            println!("{}", output::render(&response, OutputFormat::Json)?);
        }
        OutputFormat::Yaml => {
            println!("{}", output::render(&response, OutputFormat::Yaml)?);
        }
    }

    Ok(())
}
