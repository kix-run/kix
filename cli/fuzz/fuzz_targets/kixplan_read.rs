//! `PlanFile::verify`, the Kix Enterprise server's check, and every shown
//! manifest read, on plan files as uploaded, held to the bound in
//! `kix_fuzz::read_plan_file`.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| kix_fuzz::read_plan_file(data));
