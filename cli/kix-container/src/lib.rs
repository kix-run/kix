//! The container of Kix's file formats: bundles (`kix-bundle`) and plan
//! files (`kix::plan::file`).
//!
//! A container is a file in zstd's seekable format. Integers are
//! little-endian.
//!
//! - Frame 0 is a header, JSON whose `format` and `version` fields name the
//!   format. The rest of the header is the format's own.
//! - Frames 1 to n hold the files' bytes, concatenated in the order the
//!   header lists them. A frame holds whole files and at least one byte.
//! - A skippable frame ends the file: the seek table, each frame's
//!   compressed and decompressed size, with no checksums.
//!
//! `zstd -d` gives the header followed by the files. The same header and
//! files give the same bytes from the same libzstd.
//!
//! This crate knows nothing of what the files are. A format reads its
//! header from [`Container::open`], tells the container each file's size
//! with [`Container::place`], and checks each file it reads.

use std::io::{self, Read, Seek, SeekFrom, Write};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use zstd::zstd_safe;

/// The caps a reader holds a container to. Each is checked before the thing
/// it guards is read.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// The largest file, as stored.
    pub stored: u64,
    /// The largest header, decompressed.
    pub header: u64,
    /// The largest data frame, decompressed, and so the largest file.
    pub frame: u64,
    /// The most files the header may list.
    pub files: usize,
    /// The most bytes the files may add up to.
    pub content: u64,
}

/// Why a container was refused.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ContainerError {
    #[error("{0}")]
    Unreadable(String),
    /// The file does not end with a zstd seek table, so it is no container.
    #[error("it does not end with a zstd seek table")]
    NotSeekable,
    #[error("its format is '{format}' version {version}")]
    WrongFormat { format: String, version: u32 },
    #[error("{0}")]
    TooLarge(String),
    #[error("{0}")]
    Malformed(String),
}

/// The writer starts a new frame before a file that would take a frame past
/// this size. Larger frames compress better, since files of one kind repeat
/// each other.
const FRAME_FILL_BYTES: usize = 1024 * 1024;
const SEEK_TABLE_MAGIC: u32 = 0x184D_2A5E;
const SEEKABLE_MAGIC: u32 = 0x8F92_EAB1;
/// The seek table's footer: the frame count (u32), the descriptor (u8),
/// and [`SEEKABLE_MAGIC`].
const FOOTER_BYTES: usize = 9;

/// Write a container of `header` and `files`, in that order. The same
/// arguments give the same bytes from the same libzstd: zstd runs on one
/// thread at its default level, with the content size and without a
/// checksum or dictionary id.
pub fn write(header: &[u8], files: &[&[u8]], mut out: impl Write) -> io::Result<()> {
    let mut compressor = zstd::bulk::Compressor::new(zstd::DEFAULT_COMPRESSION_LEVEL)?;
    compressor.include_checksum(false)?;
    compressor.include_contentsize(true)?;
    compressor.include_dictid(false)?;
    let mut table: Vec<(u32, u32)> = Vec::new();
    let mut put = |data: &[u8], out: &mut dyn Write| -> io::Result<()> {
        let stored = compressor.compress(data)?;
        let size =
            |n: usize| u32::try_from(n).map_err(|_| io::Error::other("a frame is over 4 GiB"));
        table.push((size(stored.len())?, size(data.len())?));
        out.write_all(&stored)
    };
    put(header, &mut out)?;
    let mut frame: Vec<u8> = Vec::new();
    for bytes in files {
        if !frame.is_empty() && frame.len() + bytes.len() > FRAME_FILL_BYTES {
            put(&frame, &mut out)?;
            frame.clear();
        }
        frame.extend_from_slice(bytes);
    }
    if !frame.is_empty() {
        put(&frame, &mut out)?;
    }
    out.write_all(&seek_table(&table))?;
    out.flush()
}

/// Encode the seek table for `frames` (`(compressed_size, decompressed_size)`)
/// as a zstd skippable frame without checksums.
pub fn seek_table(frames: &[(u32, u32)]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + 8 * frames.len() + FOOTER_BYTES);
    out.extend(SEEK_TABLE_MAGIC.to_le_bytes());
    out.extend(((8 * frames.len() + FOOTER_BYTES) as u32).to_le_bytes());
    for (stored, size) in frames {
        out.extend(stored.to_le_bytes());
        out.extend(size.to_le_bytes());
    }
    out.extend((frames.len() as u32).to_le_bytes());
    out.push(0);
    out.extend(SEEKABLE_MAGIC.to_le_bytes());
    out
}

/// One frame of a container, as described by its seek table.
#[derive(Debug, Clone, Copy)]
pub struct Frame {
    /// Byte offset of the frame in the file.
    pub offset: u64,
    /// Compressed length in bytes.
    pub stored: usize,
    /// Decompressed length in bytes.
    pub size: usize,
}

/// Parsed seek table containing frame descriptors (from frame 0 onward) and
/// the raw seek-table frame bytes.
#[derive(Debug)]
pub struct SeekTable {
    pub frames: Vec<Frame>,
    pub bytes: Vec<u8>,
}

/// Return whether `input` ends with a zstd seek table, checking the file size
/// against `limits.stored` before reading.
pub fn has_seek_table(
    input: &mut (impl Read + Seek),
    limits: &Limits,
) -> Result<bool, ContainerError> {
    Ok(footer(input, limits)?.is_some())
}

/// Read the 9-byte seek table footer at the end of `input`, or return `None`
/// if the file does not end with [`SEEKABLE_MAGIC`].
fn footer(
    input: &mut (impl Read + Seek),
    limits: &Limits,
) -> Result<Option<[u8; FOOTER_BYTES]>, ContainerError> {
    let len = input.seek(SeekFrom::End(0)).map_err(unreadable)?;
    if len > limits.stored {
        return Err(too_large(format!(
            "the file is over {} bytes",
            limits.stored
        )));
    }
    let mut footer = [0u8; FOOTER_BYTES];
    if len >= FOOTER_BYTES as u64 {
        input
            .seek(SeekFrom::End(-(FOOTER_BYTES as i64)))
            .map_err(unreadable)?;
        input.read_exact(&mut footer).map_err(unreadable)?;
    }
    Ok((u32_at(&footer, 5) == SEEKABLE_MAGIC).then_some(footer))
}

/// Read the seek table at the end of `input`, and check that its frames
/// cover every byte before it and are within `limits`.
pub fn read_table(
    input: &mut (impl Read + Seek),
    limits: &Limits,
) -> Result<SeekTable, ContainerError> {
    let Some(footer) = footer(input, limits)? else {
        return Err(ContainerError::NotSeekable);
    };
    let len = input.seek(SeekFrom::End(0)).map_err(unreadable)?;
    let count = u32_at(&footer, 0) as usize;
    if footer[4] != 0 || count == 0 || count > limits.files + 1 {
        return Err(malformed(format!(
            "its seek table lists {count} frames with descriptor {:#04x}",
            footer[4]
        )));
    }
    let table_len = 8 + 8 * count + FOOTER_BYTES;
    let Some(start) = len.checked_sub(table_len as u64) else {
        return Err(malformed("its seek table is longer than the file"));
    };
    input.seek(SeekFrom::Start(start)).map_err(unreadable)?;
    let mut bytes = vec![0u8; table_len];
    input.read_exact(&mut bytes).map_err(unreadable)?;
    if u32_at(&bytes, 0) != SEEK_TABLE_MAGIC || u32_at(&bytes, 4) as usize != table_len - 8 {
        return Err(malformed("its seek table's frame header is wrong"));
    }
    let mut frames = Vec::with_capacity(count);
    let mut offset = 0u64;
    for i in 0..count {
        let stored = u32_at(&bytes, 8 + 8 * i) as usize;
        let size = u32_at(&bytes, 12 + 8 * i) as usize;
        let cap = if i == 0 { limits.header } else { limits.frame };
        if size as u64 > cap {
            return Err(too_large(format!("frame {i} is over {cap} bytes")));
        }
        if size == 0 || stored > zstd_safe::compress_bound(size) {
            return Err(malformed(format!(
                "its seek table gives frame {i} {stored} bytes for {size}"
            )));
        }
        frames.push(Frame {
            offset,
            stored,
            size,
        });
        offset += stored as u64;
    }
    if offset != start {
        return Err(malformed(format!(
            "its frames take {offset} bytes, but its seek table starts at byte {start}"
        )));
    }
    Ok(SeekTable { frames, bytes })
}

/// A container whose seek table and header have been read. Once
/// [`Container::place`] has been told the files' sizes, it reads any file,
/// or every file once with [`Container::read_all`].
#[derive(Debug)]
pub struct Container<R> {
    input: R,
    limits: Limits,
    /// Every frame, frame 0 first.
    frames: Vec<Frame>,
    /// The seek table's bytes, to tell whether the file changed while
    /// [`Container::read_all`] read it.
    table: Vec<u8>,
    /// The SHA-256 of frame 0 as stored, read from the start of the file.
    hashed_header: Sha256,
    /// Where each file lies.
    places: Vec<Place>,
    /// The frame decompressed last, by its index in `frames`.
    cached: (usize, Vec<u8>),
}

/// Frame `frame` holds `size` bytes of a file from byte `offset`.
#[derive(Debug, Clone, Copy)]
struct Place {
    frame: usize,
    offset: usize,
    size: usize,
}

impl<R: Read + Seek> Container<R> {
    /// Read the seek table and frame 0, and give the header's bytes. Refuses
    /// a header whose `format` or `version` is not `format` and `version`,
    /// reading those two fields first, so a file of another version is
    /// refused as such whatever else its header holds.
    pub fn open(
        mut input: R,
        format: &str,
        version: u32,
        limits: &Limits,
    ) -> Result<(Self, Vec<u8>), ContainerError> {
        let table = read_table(&mut input, limits)?;
        input.seek(SeekFrom::Start(0)).map_err(unreadable)?;
        let mut stream = Hashing {
            inner: &mut input,
            hasher: Sha256::new(),
        };
        let header = read_frame(&mut stream, 0, &table.frames[0])?;
        let hashed_header = stream.hasher;
        check_format(&header, format, version)?;
        let container = Container {
            input,
            limits: *limits,
            frames: table.frames,
            table: table.bytes,
            hashed_header,
            places: Vec::new(),
            cached: (usize::MAX, Vec::new()),
        };
        Ok((container, header))
    }

    /// Place each file, of these sizes in header order, in the data frame
    /// that holds it. The data frames must hold exactly these bytes, each
    /// file in one frame. An empty file goes in the frame the file before it
    /// ends in.
    pub fn place(&mut self, sizes: &[u64]) -> Result<(), ContainerError> {
        if sizes.len() > self.limits.files {
            return Err(too_large(format!(
                "the header lists more than {} files",
                self.limits.files
            )));
        }
        let listed = sizes.iter().copied().fold(0, u64::saturating_add);
        if listed > self.limits.content {
            return Err(too_large(format!(
                "the files add up to more than {} bytes",
                self.limits.content
            )));
        }
        let in_frames: u64 = self.frames[1..].iter().map(|f| f.size as u64).sum();
        if in_frames != listed {
            return Err(malformed(format!(
                "its frames hold {in_frames} bytes, but its header lists {listed}"
            )));
        }
        let mut places = Vec::with_capacity(sizes.len());
        let (mut frame, mut filled) = (1, 0);
        for (i, size) in sizes.iter().enumerate() {
            let size = *size as usize;
            if size > 0 && filled == self.frames[frame].size {
                frame += 1;
                filled = 0;
            }
            if size > 0 && filled + size > self.frames[frame].size {
                return Err(malformed(format!(
                    "file {i} runs past the end of its frame"
                )));
            }
            places.push(Place {
                frame,
                offset: filled,
                size,
            });
            filled += size;
        }
        self.places = places;
        Ok(())
    }

    /// Read and return the bytes of file `i` (indexed by the slice given to
    /// [`Container::place`]), reusing the cached frame if it was the last one
    /// decompressed.
    pub fn file(&mut self, i: usize) -> Result<Vec<u8>, ContainerError> {
        let Place {
            frame,
            offset,
            size,
        } = self.places[i];
        if size == 0 {
            return Ok(Vec::new());
        }
        if self.cached.0 != frame {
            let f = self.frames[frame];
            self.input
                .seek(SeekFrom::Start(f.offset))
                .map_err(unreadable)?;
            self.cached = (frame, read_frame(&mut self.input, frame, &f)?);
        }
        Ok(self.cached.1[offset..offset + size].to_vec())
    }

    /// Read every file once, in order, passing each to `each`, and give the
    /// SHA-256 of every byte of the file, frame 0 as [`Container::open`]
    /// read it. Holds one frame at a time. Refuses a file whose seek table
    /// changed while it was read.
    pub fn read_all<E: From<ContainerError>>(
        mut self,
        mut each: impl FnMut(usize, &[u8]) -> Result<(), E>,
    ) -> Result<(Self, String), E> {
        self.input
            .seek(SeekFrom::Start(self.frames[0].stored as u64))
            .map_err(unreadable)?;
        let mut stream = Hashing {
            inner: &mut self.input,
            hasher: self.hashed_header.clone(),
        };
        let mut frame: (usize, Vec<u8>) = (usize::MAX, Vec::new());
        for (i, place) in self.places.iter().enumerate() {
            // `place` puts every frame's bytes in some file, so each frame
            // is read once and in order.
            if place.size > 0 && frame.0 != place.frame {
                let k = place.frame;
                frame = (k, read_frame(&mut stream, k, &self.frames[k])?);
            }
            let bytes = if place.size == 0 {
                &[][..]
            } else {
                &frame.1[place.offset..place.offset + place.size]
            };
            each(i, bytes)?;
        }
        let mut rest = Vec::new();
        (&mut stream)
            .take(self.table.len() as u64 + 1)
            .read_to_end(&mut rest)
            .map_err(unreadable)?;
        if rest != self.table {
            return Err(ContainerError::Unreadable(
                "the file changed while it was read".to_string(),
            )
            .into());
        }
        let sha256 = hex(&stream.hasher.finalize());
        Ok((self, sha256))
    }
}

/// Refuse a header whose `format` and `version` are not these.
fn check_format(header: &[u8], format: &str, version: u32) -> Result<(), ContainerError> {
    #[derive(Deserialize)]
    struct Version {
        format: String,
        version: u32,
    }
    let read: Version = serde_json::from_slice(header)
        .map_err(|e| ContainerError::Unreadable(format!("the header: {e}")))?;
    if read.format != format || read.version != version {
        return Err(ContainerError::WrongFormat {
            format: read.format,
            version: read.version,
        });
    }
    Ok(())
}

/// Read frame `number` of the file from `input`'s position and decompress
/// it to the size the seek table gives.
fn read_frame(
    input: &mut impl Read,
    number: usize,
    frame: &Frame,
) -> Result<Vec<u8>, ContainerError> {
    let mut stored = vec![0u8; frame.stored];
    input.read_exact(&mut stored).map_err(unreadable)?;
    let bytes = zstd::bulk::Decompressor::new()
        .and_then(|mut d| d.decompress(&stored, frame.size))
        .map_err(|e| malformed(format!("frame {number} does not decompress: {e}")))?;
    if bytes.len() != frame.size {
        return Err(malformed(format!(
            "frame {number} decompresses to {} bytes, not {}",
            bytes.len(),
            frame.size
        )));
    }
    Ok(bytes)
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn unreadable(e: impl std::fmt::Display) -> ContainerError {
    ContainerError::Unreadable(e.to_string())
}

fn malformed(message: impl Into<String>) -> ContainerError {
    ContainerError::Malformed(message.into())
}

fn too_large(message: impl Into<String>) -> ContainerError {
    ContainerError::TooLarge(message.into())
}

/// Format `bytes` as lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A reader that hashes every byte read through it.
struct Hashing<R> {
    inner: R,
    hasher: Sha256,
}

impl<R: Read> Read for Hashing<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    const LIMITS: Limits = Limits {
        stored: 1 << 20,
        header: 1 << 16,
        frame: 1 << 16,
        files: 10,
        content: 1 << 18,
    };

    fn container(files: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        write(br#"{"format":"t","version":1}"#, files, &mut out).unwrap();
        out
    }

    #[test]
    fn files_read_back_in_any_order_and_all_at_once() {
        let files: [&[u8]; 4] = [b"one", b"", b"three", b"four"];
        let bytes = container(&files);
        let (mut c, header) = Container::open(Cursor::new(&bytes), "t", 1, &LIMITS).unwrap();
        assert_eq!(header, br#"{"format":"t","version":1}"#);
        let header = header.clone();
        c.place(&files.map(|f| f.len() as u64)).unwrap();
        for i in [3, 0, 2, 1] {
            assert_eq!(c.file(i).unwrap(), files[i]);
        }
        let mut seen = Vec::new();
        let (_, sha) = c
            .read_all(|i, b| {
                seen.push((i, b.to_vec()));
                Ok::<_, ContainerError>(())
            })
            .unwrap();
        assert_eq!(sha, hex(&Sha256::digest(&bytes)));
        assert_eq!(seen.len(), 4);
        let mut expected = header;
        expected.extend(files.concat());
        assert_eq!(
            zstd::stream::decode_all(bytes.as_slice()).unwrap(),
            expected
        );
    }

    #[test]
    fn another_format_or_version_is_refused_by_name() {
        let bytes = container(&[]);
        for (format, version) in [("u", 1), ("t", 2)] {
            assert!(matches!(
                Container::open(Cursor::new(&bytes), format, version, &LIMITS),
                Err(ContainerError::WrongFormat { .. })
            ));
        }
        assert_eq!(
            read_table(&mut Cursor::new(b"not a container"), &LIMITS).unwrap_err(),
            ContainerError::NotSeekable
        );
    }

    #[test]
    fn caps_are_checked_before_what_they_guard() {
        let bytes = container(&[&[b'x'; 100]]);
        let tight = |change: fn(&mut Limits)| {
            let mut limits = LIMITS;
            change(&mut limits);
            Container::open(Cursor::new(&bytes), "t", 1, &limits)
                .and_then(|(mut c, _)| c.place(&[100]))
        };
        for change in [
            (|l: &mut Limits| l.stored = 10) as fn(&mut Limits),
            |l| l.header = 10,
            |l| l.frame = 10,
            |l| l.content = 10,
        ] {
            assert!(matches!(tight(change), Err(ContainerError::TooLarge(_))));
        }
        assert!(tight(|_| {}).is_ok());
        let one_file = Limits { files: 1, ..LIMITS };
        let (mut c, _) = Container::open(Cursor::new(&bytes), "t", 1, &one_file).unwrap();
        assert!(matches!(
            c.place(&[50, 50]),
            Err(ContainerError::TooLarge(_))
        ));
    }
}
