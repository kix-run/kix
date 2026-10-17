//! `PlanFile::verify` and every shown manifest read, on plan files written
//! from frames the fuzzer changes decompressed, held to the bound in
//! `kix_fuzz::read_plan_file`.
#![no_main]

libfuzzer_sys::fuzz_target!(
    |data: &[u8]| kix_fuzz::read_plan_file(&kix_fuzz::bundle_of_frames(data))
);
