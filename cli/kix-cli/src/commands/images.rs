use std::collections::BTreeMap;

use miette::Result;
use serde::Serialize;

use crate::cli::ListImagesArgs;
use crate::output::{self, CommandResponse};

use super::CommandContext;

/// A single container image reference found in the cluster manifests.
#[derive(Debug, Clone, Serialize, schemars::JsonSchema, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct ImageEntry {
    /// Full image reference (for example, `"quay.io/jetstack/cert-manager-controller:v1.21.2"`).
    image: String,
    /// Workload containers that reference this image.
    sources: Vec<ImageSource>,
}

#[derive(Debug, Clone, Serialize, schemars::JsonSchema, PartialEq, Eq, PartialOrd, Ord)]
struct ImageSource {
    kind: String,
    namespace: String,
    name: String,
    container: String,
}

/// The container images of a cluster. JSON and YAML print the bare list.
#[derive(Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub(crate) struct ImagesResponse {
    images: Vec<ImageEntry>,
    /// Whether the text lists the containers that use each image.
    #[serde(skip)]
    #[schemars(skip)]
    sources: bool,
}

impl CommandResponse for ImagesResponse {
    fn text(&self) -> String {
        if self.images.is_empty() && !self.sources {
            return "No container images found.\n".to_string();
        }

        let mut out = String::new();
        for entry in &self.images {
            out.push_str(&entry.image);
            out.push('\n');
            if self.sources {
                for src in &entry.sources {
                    out.push_str(&format!(
                        "  {} {}/{} (container: {})\n",
                        src.kind, src.namespace, src.name, src.container
                    ));
                }
            }
        }
        out
    }
}

pub fn run(args: &ListImagesArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster_output = ctx.eval_cluster_or_suggest(&args.cluster)?;

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

    // Include operator-spawned images declared in package metadata.
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

    let response = ImagesResponse {
        images,
        sources: args.sources,
    };
    output::result(&response)
}
