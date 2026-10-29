//! Export formats for auditors, CI, and compliance tools.
//!
//! Provides three subcommands that serialize build and deployment metadata:
//!
//! - `sbom`: CycloneDX 1.6 Software Bill of Materials
//! - `attest`: SLSA v1 provenance as an in-toto statement
//! - `audit`: SARIF, SBOM, SLSA, OSCAL assessment, and Markdown summary
//!
//! Provenance data is also written into the cluster's `Activation` record on
//! deploy ([`receipt`]), so `kix compliance attest --from-cluster` can attest
//! a deployed activation without re-evaluating the flake.

pub mod attest;
pub mod audit;
pub mod receipt;
pub mod sbom;
pub mod shared;

use miette::Result;

use crate::cli::{ComplianceArgs, ComplianceCommand};

use super::CommandContext;

pub fn run(args: &ComplianceArgs, ctx: &mut CommandContext) -> Result<()> {
    match &args.command {
        ComplianceCommand::Sbom(a) => sbom::run(a, ctx),
        ComplianceCommand::Attest(a) => attest::run(a, ctx),
        ComplianceCommand::Audit(a) => audit::run(a, ctx),
    }
}
