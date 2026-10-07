//! `PathsChecked::read` on bundles written from frames the fuzzer
//! changes decompressed, held to the bound in `kix_fuzz::check_paths`.
#![no_main]

libfuzzer_sys::fuzz_target!(|data: &[u8]| kix_fuzz::check_paths(&kix_fuzz::bundle_of_frames(data)));
