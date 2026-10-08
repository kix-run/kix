//! `PathsChecked::read`, the Kix Enterprise server's check, on bundle
//! files as uploaded, held to the bound in `kix_fuzz::check_paths`.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| kix_fuzz::check_paths(data));
