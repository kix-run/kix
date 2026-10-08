#![deny(clippy::print_stdout, clippy::print_stderr)]

//! Nix-based Kubernetes manifest generation and deployment.
//!
//! Three module groups:
//!
//! - [`eval`]: Nix evaluation, store graphs, caching, and error translation
//! - [`manifest`]: Kubernetes types, diffs, annotation stamping, and validation
//! - [`cluster`]: apply, fetch, DAG, readiness, activation lifecycle, and reconcile
//!
//! Four smaller modules sit beside them: [`build_source`], the checked build
//! a command plans and deploys and where it came from, [`pins`], the committed record of
//! what each image reference resolved to, [`registry`], the one place Kix asks
//! a container registry a question, and [`text`], for printing text kix did
//! not write.

pub mod build_source;
pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod manifest;
pub mod pins;
pub mod registry;
pub mod text;

/// Counts the bytes each test thread has allocated, so a test can bound
/// what a call keeps in memory.
#[cfg(test)]
pub(crate) mod allocated {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    thread_local! {
        static NOW: Cell<isize> = const { Cell::new(0) };
        static PEAK: Cell<isize> = const { Cell::new(0) };
    }

    struct Counting;

    fn add(bytes: isize) {
        let _ = NOW.try_with(|now| {
            now.set(now.get() + bytes);
            let _ = PEAK.try_with(|peak| peak.set(peak.get().max(now.get())));
        });
    }

    // SAFETY: each method passes its arguments to `System` unchanged.
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }
        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc_zeroed(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }
        unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
            unsafe { System.dealloc(p, layout) };
            add(-(layout.size() as isize));
        }
        unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            let q = unsafe { System.realloc(p, layout, new_size) };
            if !q.is_null() {
                add(new_size as isize - layout.size() as isize);
            }
            q
        }
    }

    #[global_allocator]
    static COUNTING: Counting = Counting;

    /// The most bytes this thread held while `f` ran, beyond what it held
    /// when `f` started.
    pub fn peak_during<T>(f: impl FnOnce() -> T) -> (T, usize) {
        let start = NOW.with(Cell::get);
        PEAK.with(|peak| peak.set(start));
        let out = f();
        (out, (PEAK.with(Cell::get) - start).max(0) as usize)
    }
}
