//! `Bundle::read`, what `kix graph`, `kix plan` and `kix deploy` run on a
//! bundle, on bundle files as uploaded.
#![no_main]

use std::io::Cursor;

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    let _ = kix::eval::bundle::Bundle::read(Cursor::new(data));
});
