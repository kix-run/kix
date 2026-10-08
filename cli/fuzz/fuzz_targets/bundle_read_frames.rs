//! `Bundle::read` on bundles written from frames the fuzzer changes
//! decompressed.
#![no_main]

use std::io::Cursor;

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    let bundle = kix_fuzz::bundle_of_frames(data);
    let _ = kix::eval::bundle::Bundle::read(Cursor::new(bundle.as_slice()));
});
