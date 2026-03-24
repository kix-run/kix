#![deny(clippy::print_stdout, clippy::print_stderr)]

//! K8s cluster operations — fetching, deploying, status, graph.

pub mod apply;
pub mod fetch;
pub mod graph;
pub mod readiness;
pub mod waves;

pub use graph::ResourceGraph;
