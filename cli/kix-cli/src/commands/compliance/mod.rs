//! Export formats for auditors, CI, and compliance tools.
//!
//! Three subcommands, each a serialization of data kix already has:
//!
//! - `sbom`: CycloneDX 1.6 Software Bill of Materials
//! - `attest`: SLSA v1 provenance as an in-toto statement
//! - `audit`: SARIF, SBOM, SLSA, OSCAL assessment, and markdown summary
//!
//! The provenance those subcommands print is the same provenance a deploy
//! writes into the Activation record ([`receipt`]), so `attest --from-cluster`
//! reads a deploy that happened rather than recomputing one that would.
//!
//! See `v2_discussions/61_compliance_exports.md`.

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
