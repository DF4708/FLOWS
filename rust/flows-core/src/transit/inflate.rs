// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Raw DEFLATE (RFC 1951) and CRC-32, pure std — so a big city's schedule can
//! stay compressed on a phone and be unpacked as it is read.
//!
//! Chicago's `stop_times.txt` is 367 MB unpacked and 54 MB as it sits in the
//! CTA's archive. The app used to unpack each file whole in memory before
//! writing it out — the compressed bytes, a buffer the size of the unpacked
//! file, and a copy — which is why any feed past 80 MB was refused on a phone.
//! Now the device keeps each member exactly as the archive stores it (a
//! [`PACKED_SUFFIX`] file: a 16-byte header, then the raw DEFLATE data) and the
//! timetable builder reads it through [`Inflate`], which holds a 32 KiB window
//! and a 256 KiB output buffer whatever the file's size.
//!
//! The header carries the CRC-32 and length the archive's directory gave for
//! the member, and both are checked when the stream ends: a download cut short
//! or corrupted is an error, never a timetable quietly missing its last trips.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read};
use std::path::Path;

/// What a packed member's file name ends in: `stop_times.txt.fz`.
pub const PACKED_SUFFIX: &str = ".fz";

/// The first four bytes of a packed member.
pub const PACKED_MAGIC: [u8; 4] = *b"FZ01";

/// Bytes before the DEFLATE data: magic, CRC-32 (LE), unpacked length (LE u64).
pub const PACKED_HEADER_LEN: usize = 16;

// -----------------------------------------------------------------------------
// CRC-32 (IEEE, reflected — the one ZIP stores).
// -----------------------------------------------------------------------------

const CRC_TABLE: [u32; 256] = crc_table();

const fn crc_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut n = 0;
    while n < 256 {
        let mut c = n as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
            k += 1;
        }
        table[n] = c;
        n += 1;
    }
    table
}

/// Extend a CRC-32 over `bytes`. Start from 0; chained calls give the CRC of
/// the concatenation.
#[must_use]
pub fn crc32_update(crc: u32, bytes: &[u8]) -> u32 {
    let mut c = !crc;
    for &b in bytes {
        c = CRC_TABLE[((c ^ u32::from(b)) & 0xFF) as usize] ^ (c >> 8);
    }
    !c
}

// -----------------------------------------------------------------------------
// Bits, least significant first, as DEFLATE packs them.
// -----------------------------------------------------------------------------

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("deflate: {msg}"))
}

fn truncated() -> io::Error {
    io::Error::new(
        io::ErrorKind::UnexpectedEof,
        "deflate: the data ends before the stream does",
    )
}

struct Bits<R: Read> {
    src: R,
    input: Box<[u8]>,
    pos: usize,
    len: usize,
    eof: bool,
    buf: u64,
    cnt: u32,
}

impl<R: Read> Bits<R> {
    fn new(src: R) -> Self {
        Bits {
            src,
            input: vec![0u8; 64 * 1024].into_boxed_slice(),
            pos: 0,
            len: 0,
            eof: false,
            buf: 0,
            cnt: 0,
        }
    }

    /// Top the bit buffer up to at least 57 bits, or to whatever is left.
    fn refill(&mut self) -> io::Result<()> {
        while self.cnt <= 56 {
            if self.pos == self.len {
                if self.eof {
                    return Ok(());
                }
                self.len = loop {
                    match self.src.read(&mut self.input) {
                        Ok(n) => break n,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e),
                    }
                };
                self.pos = 0;
                if self.len == 0 {
                    self.eof = true;
                    return Ok(());
                }
            }
            self.buf |= u64::from(self.input[self.pos]) << self.cnt;
            self.pos += 1;
            self.cnt += 8;
        }
        Ok(())
    }

    fn need(&mut self, n: u32) -> io::Result<()> {
        if self.cnt < n {
            self.refill()?;
            if self.cnt < n {
                return Err(truncated());
            }
        }
        Ok(())
    }

    fn take(&mut self, n: u32) -> io::Result<u32> {
        if n == 0 {
            return Ok(0);
        }
        self.need(n)?;
        let v = (self.buf & ((1u64 << n) - 1)) as u32;
        self.buf >>= n;
        self.cnt -= n;
        Ok(v)
    }

    /// Drop the bits left in the current byte (before a stored block).
    fn align(&mut self) {
        let r = self.cnt % 8;
        self.buf >>= r;
        self.cnt -= r;
    }
}

// -----------------------------------------------------------------------------
// Canonical Huffman codes.
// -----------------------------------------------------------------------------

/// Codes up to this long decode with one table lookup; longer ones (rare in
/// real data) walk the canonical code a bit at a time.
const FAST_BITS: u32 = 10;

struct Huffman {
    /// `(symbol << 4) | length` by the next [`FAST_BITS`] bits; 0 = not here.
    fast: Vec<u16>,
    counts: [u16; 16],
    symbols: Vec<u16>,
}

/// Which kind of code a table is — it decides whether an incomplete code is
/// tolerated, exactly as zlib decides it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// The code-length code of a dynamic block: must be complete.
    Lengths,
    /// Literal/length or distance codes: a lone one-bit code is allowed.
    Symbols,
}

impl Huffman {
    fn new(lengths: &[u8], kind: Kind) -> io::Result<Self> {
        let mut counts = [0u16; 16];
        for &l in lengths {
            counts[usize::from(l)] += 1;
        }
        counts[0] = 0;
        let max = (1..16).rev().find(|&l| counts[l] != 0).unwrap_or(0);

        // Over-subscribed codes are corrupt; incomplete ones only in the
        // single-code case zlib also accepts (and an empty distance code,
        // which is fine until a match tries to use it).
        let mut left: i32 = 1;
        for &count in counts.iter().skip(1) {
            left <<= 1;
            left -= i32::from(count);
            if left < 0 {
                return Err(bad("over-subscribed code"));
            }
        }
        if left > 0 && max != 0 && (kind == Kind::Lengths || max != 1) {
            return Err(bad("incomplete code"));
        }

        let mut offs = [0u16; 16];
        for l in 1..15 {
            offs[l + 1] = offs[l] + counts[l];
        }
        let mut symbols = vec![0u16; lengths.len()];
        for (sym, &l) in lengths.iter().enumerate() {
            if l != 0 {
                symbols[usize::from(offs[usize::from(l)])] = sym as u16;
                offs[usize::from(l)] += 1;
            }
        }

        let mut fast = vec![0u16; 1 << FAST_BITS];
        let mut next = [0u32; 16];
        let mut code = 0u32;
        for bits in 1..16 {
            code = (code + u32::from(counts[bits - 1])) << 1;
            next[bits] = code;
        }
        for (sym, &l) in lengths.iter().enumerate() {
            let l = u32::from(l);
            if l == 0 {
                continue;
            }
            let c = next[l as usize];
            next[l as usize] += 1;
            if l > FAST_BITS {
                continue;
            }
            // DEFLATE sends Huffman codes most significant bit first into a
            // least-significant-first stream: index the table by the reverse.
            let rev = c.reverse_bits() >> (32 - l);
            let entry = ((sym as u16) << 4) | l as u16;
            let mut i = rev;
            while i < (1 << FAST_BITS) {
                fast[i as usize] = entry;
                i += 1 << l;
            }
        }
        Ok(Huffman {
            fast,
            counts,
            symbols,
        })
    }

    fn decode<R: Read>(&self, bits: &mut Bits<R>) -> io::Result<u16> {
        if bits.cnt < 15 {
            bits.refill()?;
        }
        let e = self.fast[(bits.buf & ((1 << FAST_BITS) - 1)) as usize];
        if e != 0 {
            let len = u32::from(e & 15);
            if len > bits.cnt {
                return Err(truncated());
            }
            bits.buf >>= len;
            bits.cnt -= len;
            return Ok(e >> 4);
        }
        // The long way: one bit at a time down the canonical code.
        let mut peek = bits.buf;
        let (mut code, mut first, mut index) = (0i32, 0i32, 0i32);
        for len in 1..16u32 {
            code |= (peek & 1) as i32;
            peek >>= 1;
            let count = i32::from(self.counts[len as usize]);
            if code - first < count {
                if len > bits.cnt {
                    return Err(truncated());
                }
                bits.buf >>= len;
                bits.cnt -= len;
                return Ok(self.symbols[(index + code - first) as usize]);
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        Err(if bits.cnt < 15 {
            truncated()
        } else {
            bad("a code no table holds")
        })
    }
}

const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LENGTH_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];
/// The order a dynamic block lists its code-length code lengths in.
const LENGTH_ORDER: [usize; 19] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

fn fixed_tables() -> io::Result<(Huffman, Huffman)> {
    let mut lit = [0u8; 288];
    lit[..144].fill(8);
    lit[144..256].fill(9);
    lit[256..280].fill(7);
    lit[280..].fill(8);
    Ok((
        Huffman::new(&lit, Kind::Symbols)?,
        // 32 codes, as the RFC lists them: 30 and 31 exist in the code but
        // never in valid data, and without them the code is incomplete.
        Huffman::new(&[5u8; 32], Kind::Symbols)?,
    ))
}

// -----------------------------------------------------------------------------
// The streaming decoder.
// -----------------------------------------------------------------------------

/// How far back a match may reach.
const WINDOW: usize = 32 * 1024;
/// Output decoded per refill, on top of the window kept for matches.
const CHUNK: usize = 256 * 1024;
/// The longest a single match can be.
const MAX_MATCH: usize = 258;

enum State {
    Header,
    Stored(usize),
    Codes,
    Done,
}

/// A raw DEFLATE stream, unpacked as it is read. Memory is fixed — a 64 KiB
/// input buffer, the 32 KiB window and a 256 KiB output chunk — whatever the
/// size of what it unpacks.
pub struct Inflate<R: Read> {
    bits: Bits<R>,
    /// The window (already handed out) followed by bytes not yet read.
    out: Vec<u8>,
    read_pos: usize,
    state: State,
    last: bool,
    tables: Option<(Huffman, Huffman)>,
    total: u64,
    crc: u32,
    expect: Option<(u64, u32)>,
}

impl<R: Read> Inflate<R> {
    pub fn new(src: R) -> Self {
        Inflate {
            bits: Bits::new(src),
            out: Vec::with_capacity(WINDOW + CHUNK),
            read_pos: 0,
            state: State::Header,
            last: false,
            tables: None,
            total: 0,
            crc: 0,
            expect: None,
        }
    }

    /// Check the whole stream against the length and CRC-32 its archive
    /// recorded: a mismatch makes the end of the stream an error.
    #[must_use]
    pub fn expecting(mut self, length: u64, crc: u32) -> Self {
        self.expect = Some((length, crc));
        self
    }

    /// Bytes unpacked so far.
    pub fn total_out(&self) -> u64 {
        self.total
    }

    fn fill(&mut self) -> io::Result<()> {
        if self.out.len() > WINDOW {
            let drop = self.out.len() - WINDOW;
            self.out.drain(..drop);
        }
        self.read_pos = self.out.len();
        let started = self.out.len();
        while self.out.len() + MAX_MATCH <= WINDOW + CHUNK {
            match self.state {
                State::Done => break,
                State::Header => self.block_header()?,
                State::Stored(n) => {
                    let room = WINDOW + CHUNK - self.out.len();
                    let take = n.min(room);
                    for _ in 0..take {
                        let b = self.bits.take(8)? as u8;
                        self.out.push(b);
                    }
                    self.state = if n > take {
                        State::Stored(n - take)
                    } else if self.last {
                        State::Done
                    } else {
                        State::Header
                    };
                }
                State::Codes => self.codes()?,
            }
        }
        let fresh = &self.out[started..];
        self.crc = crc32_update(self.crc, fresh);
        self.total += fresh.len() as u64;
        if matches!(self.state, State::Done) {
            if let Some((length, crc)) = self.expect {
                if length != self.total || crc != self.crc {
                    return Err(bad(&format!(
                        "unpacked {} bytes with CRC {:08x}; the archive said {} and {:08x}",
                        self.total, self.crc, length, crc
                    )));
                }
            }
        }
        Ok(())
    }

    fn block_header(&mut self) -> io::Result<()> {
        self.last = self.bits.take(1)? == 1;
        match self.bits.take(2)? {
            0 => {
                self.bits.align();
                let len = self.bits.take(16)?;
                let nlen = self.bits.take(16)?;
                if len != !nlen & 0xFFFF {
                    return Err(bad("a stored block's length does not check"));
                }
                self.state = if len == 0 && self.last {
                    State::Done
                } else if len == 0 {
                    State::Header
                } else {
                    State::Stored(len as usize)
                };
            }
            1 => {
                self.tables = Some(fixed_tables()?);
                self.state = State::Codes;
            }
            2 => {
                self.tables = Some(self.dynamic_tables()?);
                self.state = State::Codes;
            }
            _ => return Err(bad("reserved block type")),
        }
        Ok(())
    }

    fn dynamic_tables(&mut self) -> io::Result<(Huffman, Huffman)> {
        let nlit = self.bits.take(5)? as usize + 257;
        let ndist = self.bits.take(5)? as usize + 1;
        let ncode = self.bits.take(4)? as usize + 4;
        if nlit > 286 || ndist > 30 {
            return Err(bad("too many codes"));
        }
        let mut code_lengths = [0u8; 19];
        for &i in LENGTH_ORDER.iter().take(ncode) {
            code_lengths[i] = self.bits.take(3)? as u8;
        }
        let lengths_code = Huffman::new(&code_lengths, Kind::Lengths)?;

        let mut lengths = [0u8; 286 + 30];
        let mut i = 0;
        while i < nlit + ndist {
            let sym = lengths_code.decode(&mut self.bits)?;
            let (value, repeat) = match sym {
                0..=15 => (sym as u8, 1),
                16 => {
                    if i == 0 {
                        return Err(bad("a repeat with nothing to repeat"));
                    }
                    (lengths[i - 1], 3 + self.bits.take(2)? as usize)
                }
                17 => (0, 3 + self.bits.take(3)? as usize),
                18 => (0, 11 + self.bits.take(7)? as usize),
                _ => return Err(bad("a code-length symbol past 18")),
            };
            if i + repeat > nlit + ndist {
                return Err(bad("code lengths run past the table"));
            }
            lengths[i..i + repeat].fill(value);
            i += repeat;
        }
        if lengths[256] == 0 {
            return Err(bad("no end-of-block code"));
        }
        Ok((
            Huffman::new(&lengths[..nlit], Kind::Symbols)?,
            Huffman::new(&lengths[nlit..nlit + ndist], Kind::Symbols)?,
        ))
    }

    fn codes(&mut self) -> io::Result<()> {
        let Some((lit, dist)) = self.tables.as_ref() else {
            return Err(bad("codes with no tables"));
        };
        while self.out.len() + MAX_MATCH <= WINDOW + CHUNK {
            let sym = lit.decode(&mut self.bits)?;
            if sym < 256 {
                self.out.push(sym as u8);
                continue;
            }
            if sym == 256 {
                self.state = if self.last {
                    State::Done
                } else {
                    State::Header
                };
                return Ok(());
            }
            let li = usize::from(sym - 257);
            if li >= LENGTH_BASE.len() {
                return Err(bad("a length symbol past 285"));
            }
            let len = usize::from(LENGTH_BASE[li])
                + self.bits.take(u32::from(LENGTH_EXTRA[li]))? as usize;
            let di = usize::from(dist.decode(&mut self.bits)?);
            if di >= DIST_BASE.len() {
                return Err(bad("a distance symbol past 29"));
            }
            let d =
                usize::from(DIST_BASE[di]) + self.bits.take(u32::from(DIST_EXTRA[di]))? as usize;
            if d > self.out.len() {
                return Err(bad("a match reaches back before the start"));
            }
            let start = self.out.len() - d;
            if d >= len {
                self.out.extend_from_within(start..start + len);
            } else {
                // Overlapping: each byte copied may be the source of the next.
                for k in 0..len {
                    let b = self.out[start + k];
                    self.out.push(b);
                }
            }
        }
        Ok(())
    }
}

impl<R: Read> Read for Inflate<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let avail = self.fill_buf()?;
        let n = avail.len().min(buf.len());
        buf[..n].copy_from_slice(&avail[..n]);
        self.consume(n);
        Ok(n)
    }
}

impl<R: Read> BufRead for Inflate<R> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        if self.read_pos == self.out.len() && !matches!(self.state, State::Done) {
            self.fill()?;
        }
        Ok(&self.out[self.read_pos..])
    }

    fn consume(&mut self, amt: usize) {
        self.read_pos = (self.read_pos + amt).min(self.out.len());
    }
}

// -----------------------------------------------------------------------------
// Feed members on disk: plain, or packed as the archive stored them.
// -----------------------------------------------------------------------------

/// The CRC-32 and unpacked length a packed member's header records.
pub fn packed_header(bytes: &[u8]) -> io::Result<(u32, u64)> {
    if bytes.len() < PACKED_HEADER_LEN || bytes[..4] != PACKED_MAGIC {
        return Err(bad("not a packed feed member"));
    }
    let crc = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    let mut len = [0u8; 8];
    len.copy_from_slice(&bytes[8..16]);
    Ok((crc, u64::from_le_bytes(len)))
}

/// Open one of a feed's files — `stop_times.txt` as the publisher wrote it,
/// or `stop_times.txt.fz` as the archive stored it — as a line reader. When
/// both are present (a refresh interrupted between writing one and deleting
/// the other) the newer wins. `None` when neither exists.
pub fn open_member(dir: &Path, name: &str) -> io::Result<Option<Box<dyn BufRead>>> {
    let plain = dir.join(name);
    let packed = dir.join(format!("{name}{PACKED_SUFFIX}"));
    let modified = |p: &Path| p.metadata().and_then(|m| m.modified()).ok();
    let use_packed = match (plain.is_file(), packed.is_file()) {
        (false, false) => return Ok(None),
        (true, false) => false,
        (false, true) => true,
        (true, true) => modified(&packed) >= modified(&plain),
    };
    if !use_packed {
        return Ok(Some(Box::new(BufReader::with_capacity(
            64 * 1024,
            File::open(plain)?,
        ))));
    }
    let mut file = File::open(packed)?;
    let mut head = [0u8; PACKED_HEADER_LEN];
    file.read_exact(&mut head)?;
    let (crc, len) = packed_header(&head)?;
    Ok(Some(Box::new(Inflate::new(file).expecting(len, crc))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unpack(raw: &[u8]) -> io::Result<Vec<u8>> {
        let mut out = Vec::new();
        Inflate::new(raw).read_to_end(&mut out)?;
        Ok(out)
    }

    /// Stored blocks of at most `block` bytes: the simplest valid stream.
    fn stored(data: &[u8], block: usize) -> Vec<u8> {
        let mut out = Vec::new();
        let chunks: Vec<&[u8]> = if data.is_empty() {
            vec![&[][..]]
        } else {
            data.chunks(block).collect()
        };
        for (i, c) in chunks.iter().enumerate() {
            out.push(u8::from(i + 1 == chunks.len())); // BFINAL, BTYPE=00
            let len = c.len() as u16;
            out.extend_from_slice(&len.to_le_bytes());
            out.extend_from_slice(&(!len).to_le_bytes());
            out.extend_from_slice(c);
        }
        out
    }

    /// A fixed-Huffman encoder for literals and matches — just enough to put
    /// matches exactly where a test wants them.
    enum Op {
        Lit(u8),
        Match(usize, usize), // (length, distance)
    }

    struct Writer {
        out: Vec<u8>,
        acc: u64,
        n: u32,
    }

    impl Writer {
        fn bits(&mut self, v: u32, n: u32) {
            self.acc |= u64::from(v) << self.n;
            self.n += n;
            while self.n >= 8 {
                self.out.push(self.acc as u8);
                self.acc >>= 8;
                self.n -= 8;
            }
        }
        fn code(&mut self, code: u32, len: u32) {
            self.bits(code.reverse_bits() >> (32 - len), len);
        }
        fn lit_len(&mut self, sym: u32) {
            match sym {
                0..=143 => self.code(0x30 + sym, 8),
                144..=255 => self.code(0x190 + sym - 144, 9),
                256..=279 => self.code(sym - 256, 7),
                _ => self.code(0xC0 + sym - 280, 8),
            }
        }
    }

    fn fixed(ops: &[Op]) -> Vec<u8> {
        let mut w = Writer {
            out: Vec::new(),
            acc: 0,
            n: 0,
        };
        w.bits(1, 1); // BFINAL
        w.bits(1, 2); // BTYPE=01
        for op in ops {
            match *op {
                Op::Lit(b) => w.lit_len(u32::from(b)),
                Op::Match(len, d) => {
                    let li = LENGTH_BASE
                        .iter()
                        .rposition(|&b| usize::from(b) <= len)
                        .unwrap();
                    w.lit_len(257 + li as u32);
                    w.bits(
                        (len - usize::from(LENGTH_BASE[li])) as u32,
                        u32::from(LENGTH_EXTRA[li]),
                    );
                    let di = DIST_BASE
                        .iter()
                        .rposition(|&b| usize::from(b) <= d)
                        .unwrap();
                    w.code(di as u32, 5);
                    w.bits(
                        (d - usize::from(DIST_BASE[di])) as u32,
                        u32::from(DIST_EXTRA[di]),
                    );
                }
            }
        }
        w.lit_len(256);
        if w.n > 0 {
            w.out.push(w.acc as u8);
        }
        w.out
    }

    #[test]
    fn crc32_matches_the_standard_check_value() {
        assert_eq!(crc32_update(0, b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32_update(0, b""), 0);
        let whole = crc32_update(0, b"hello, world");
        assert_eq!(crc32_update(crc32_update(0, b"hello, "), b"world"), whole);
    }

    #[test]
    fn stored_blocks_come_back_as_they_went_in() {
        let data: Vec<u8> = (0..700_000u32).map(|i| (i * 7 % 251) as u8).collect();
        assert_eq!(unpack(&stored(&data, 65_535)).unwrap(), data);
        assert_eq!(unpack(&stored(b"", 10)).unwrap(), b"");
    }

    #[test]
    fn matches_reach_back_across_every_refill() {
        // 40 KB of varied literals, then matches at the far edge of the
        // window (32,768 back) and overlapping runs (1 back), repeated until
        // the output is several refills long — each refill drops old output
        // and a match must still find the bytes it points at.
        let mut ops = Vec::new();
        let mut expect: Vec<u8> = Vec::new();
        for i in 0..40_000u32 {
            let b = (i.wrapping_mul(2_654_435_761) >> 24) as u8;
            ops.push(Op::Lit(b));
            expect.push(b);
        }
        while expect.len() < 900_000 {
            for (len, d) in [(258usize, 32_768usize), (3, 1), (100, 1), (258, 4_097)] {
                ops.push(Op::Match(len, d));
                let start = expect.len() - d;
                for k in 0..len {
                    let b = expect[start + k];
                    expect.push(b);
                }
            }
            ops.push(Op::Lit(b'x'));
            expect.push(b'x');
        }
        let raw = fixed(&ops);
        let got = unpack(&raw).unwrap();
        assert_eq!(got.len(), expect.len());
        assert!(got == expect, "every byte, in order");

        // And through the checked path, with the right and the wrong CRC.
        let crc = crc32_update(0, &expect);
        let mut out = Vec::new();
        Inflate::new(&raw[..])
            .expecting(expect.len() as u64, crc)
            .read_to_end(&mut out)
            .unwrap();
        let err = Inflate::new(&raw[..])
            .expecting(expect.len() as u64, crc ^ 1)
            .read_to_end(&mut Vec::new())
            .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn a_dynamic_block_from_gzip_unpacks_to_its_text() {
        // `gzip -9 -n` of GTFS-shaped rows, header and trailer removed: a
        // dynamic-Huffman block as real archives carry them.
        let text: String = (0..80)
            .map(|i| {
                format!(
                    "t{},{:02}:{:02}:00,{:02}:{:02}:00,S{},{}\n",
                    i / 20,
                    6 + i / 60,
                    i % 60,
                    6 + i / 60,
                    i % 60,
                    i % 37,
                    i % 20 + 1
                )
            })
            .collect();
        let got = unpack(GZIP_ROWS).unwrap();
        assert_eq!(String::from_utf8(got).unwrap(), text);
        assert_eq!(crc32_update(0, text.as_bytes()), GZIP_ROWS_CRC);
    }

    #[test]
    fn a_stream_cut_short_is_an_error_not_a_shorter_file() {
        let raw = GZIP_ROWS;
        for cut in [1, raw.len() / 3, raw.len() / 2, raw.len() - 1] {
            let err = unpack(&raw[..cut]).unwrap_err();
            assert!(
                matches!(
                    err.kind(),
                    io::ErrorKind::UnexpectedEof | io::ErrorKind::InvalidData
                ),
                "cut at {cut}: {err}"
            );
        }
        assert!(unpack(&[]).is_err(), "nothing at all is not an empty file");
    }

    #[test]
    fn rubbish_is_refused() {
        assert!(unpack(&[0b111]).is_err(), "reserved block type 3");
        let mut s = stored(b"abc", 10);
        s[3] ^= 0xFF; // NLEN no longer the complement of LEN
        assert!(unpack(&s).is_err());
        // A match reaching before the start of the output.
        assert!(unpack(&fixed(&[Op::Lit(b'a'), Op::Match(3, 2)])).is_err());
    }

    #[test]
    fn a_member_opens_plain_or_packed_and_the_newer_wins() {
        let dir = std::env::temp_dir().join(format!("flows_inflate_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let body = b"stop_id,stop_name\nA,Alpha\n";
        let read = |name: &str| -> Option<Vec<u8>> {
            open_member(&dir, name).unwrap().map(|mut r| {
                let mut v = Vec::new();
                r.read_to_end(&mut v).unwrap();
                v
            })
        };
        assert!(read("stops.txt").is_none(), "neither form");

        let mut packed = PACKED_MAGIC.to_vec();
        packed.extend_from_slice(&crc32_update(0, body).to_le_bytes());
        packed.extend_from_slice(&(body.len() as u64).to_le_bytes());
        packed.extend_from_slice(&stored(body, 1_000));
        std::fs::write(dir.join("stops.txt.fz"), &packed).unwrap();
        assert_eq!(read("stops.txt").unwrap(), body, "packed alone");

        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(dir.join("stops.txt"), b"stop_id\nNEWER\n").unwrap();
        assert_eq!(
            read("stops.txt").unwrap(),
            b"stop_id\nNEWER\n",
            "the newer file"
        );

        std::fs::remove_file(dir.join("stops.txt")).unwrap();
        let mut bad_header = packed.clone();
        bad_header[0] = b'X';
        std::fs::write(dir.join("stops.txt.fz"), &bad_header).unwrap();
        assert!(open_member(&dir, "stops.txt").is_err(), "not our header");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `gzip -9 -n` of the rows `a_dynamic_block_from_gzip_unpacks_to_its_text`
    /// builds, with gzip's 10-byte header and 8-byte trailer removed.
    const GZIP_ROWS: &[u8] = &[
        0x45, 0x95, 0x41, 0x8e, 0xa0, 0x30, 0x0c, 0x04, 0xef, 0xf3, 0x96, 0x1c, 0xb0, 0x1d, 0x07,
        0x98, 0x6f, 0xf8, 0x2b, 0xf3, 0x7f, 0x2d, 0xb8, 0x53, 0xac, 0xc4, 0xa1, 0x95, 0xba, 0x95,
        0xba, 0xf1, 0xdf, 0x31, 0x8e, 0xf5, 0x7b, 0x1c, 0xcf, 0xf7, 0x3f, 0xd4, 0x31, 0xec, 0xe7,
        0x4f, 0x0f, 0x06, 0xe9, 0x50, 0x36, 0x1c, 0xe2, 0x90, 0x0e, 0xe5, 0x23, 0x20, 0x01, 0xe9,
        0x50, 0x31, 0x26, 0x64, 0x42, 0x3a, 0xd4, 0x1c, 0x09, 0x49, 0x48, 0x87, 0xca, 0xb1, 0x20,
        0x0b, 0xd2, 0xa1, 0xd6, 0x38, 0x21, 0x27, 0xa4, 0x43, 0x9d, 0xe3, 0x82, 0x5c, 0x90, 0x0e,
        0x75, 0x8d, 0x1b, 0x72, 0x43, 0x3a, 0xd4, 0x3d, 0xec, 0xd8, 0xc8, 0x90, 0xa0, 0x50, 0xf6,
        0x58, 0x40, 0x83, 0xa1, 0xc1, 0xb6, 0x06, 0x1b, 0x86, 0x08, 0x43, 0x84, 0x42, 0x99, 0x0f,
        0x43, 0x85, 0xa1, 0x42, 0xa1, 0x2c, 0x86, 0x21, 0xc3, 0x90, 0xa1, 0x50, 0x36, 0x87, 0xa1,
        0xc3, 0xd0, 0xa1, 0x50, 0x96, 0xc3, 0x10, 0x62, 0x08, 0x51, 0x28, 0x5b, 0xc3, 0x50, 0x62,
        0x28, 0x51, 0x28, 0x3b, 0x87, 0x21, 0xc5, 0x90, 0xa2, 0x50, 0x76, 0x0d, 0x43, 0x8b, 0xa1,
        0x45, 0xa1, 0xec, 0x1e, 0xfe, 0x78, 0xb1, 0xf7, 0xc9, 0xf1, 0xa2, 0x50, 0xde, 0xed, 0x10,
        0x42, 0x8b, 0x42, 0x79, 0xd7, 0x43, 0x08, 0x2b, 0xbe, 0xeb, 0xd1, 0xfd, 0x10, 0x42, 0x8a,
        0x42, 0x79, 0x17, 0x44, 0x08, 0x27, 0x0a, 0xe5, 0xdd, 0x10, 0x21, 0x94, 0x28, 0x94, 0x77,
        0x45, 0x84, 0x30, 0xa2, 0x50, 0xde, 0x1d, 0x11, 0x42, 0x88, 0x42, 0x79, 0x97, 0x44, 0x08,
        0x1f, 0x0a, 0xe5, 0xdd, 0x12, 0x21, 0x74, 0x28, 0x94, 0xab, 0x26, 0xcd, 0x02, 0x1d, 0x0a,
        0x15, 0xaa, 0x89, 0x18, 0x3e, 0x14, 0x2a, 0x54, 0x13, 0x31, 0x84, 0x28, 0x54, 0xa8, 0x26,
        0x62, 0x18, 0x89, 0xbd, 0x18, 0xd5, 0x44, 0x0c, 0x25, 0x0a, 0x15, 0xaa, 0x89, 0x18, 0x4e,
        0x14, 0x2a, 0x54, 0x13, 0x31, 0xa4, 0x28, 0x54, 0xa8, 0x26, 0x62, 0x58, 0x51, 0x78, 0xf7,
        0x8e, 0x95, 0xc0, 0x4a, 0xec, 0x96, 0x74, 0x49, 0x84, 0xb0, 0x12, 0xdb, 0x4a, 0x77, 0xc4,
        0xdf, 0x97, 0x89, 0x94, 0xb9, 0xa5, 0xbc, 0x15, 0x11, 0x41, 0x89, 0xc2, 0x33, 0x79, 0x87,
        0x20, 0x44, 0xe1, 0x99, 0x7c, 0x40, 0xd0, 0xa1, 0xf0, 0x4c, 0x7e, 0x42, 0x90, 0xa1, 0xf0,
        0x4c, 0x3e, 0x21, 0xa8, 0x50, 0x78, 0x26, 0xbf, 0x20, 0x88, 0x50, 0x78, 0x26, 0x7f, 0x42,
        0xd0, 0x30, 0x4f, 0x16, 0x7f, 0x81, 0xd0, 0x30, 0x2f, 0x06, 0x7f, 0x83, 0xd0, 0x30, 0xef,
        0x6f, 0xef, 0x78, 0x48, 0x3c, 0xe4, 0xf1, 0xed, 0x1d, 0x13, 0x89, 0x89, 0xb4, 0x6f, 0xef,
        0xb8, 0x48, 0x5c, 0xa4, 0x7f, 0x7b, 0xc7, 0x46, 0x62, 0x23, 0xe3, 0xdb, 0x3b, 0x3e, 0x12,
        0x1f, 0x39, 0xbf, 0xbd, 0x63, 0x24, 0x31, 0x92, 0xf9, 0xed, 0x1d, 0x27, 0x89, 0x93, 0x5c,
        0xec, 0xdd, 0xb0, 0x92, 0x58, 0xc9, 0xf3, 0xdb, 0x3b, 0x5a, 0x12, 0x2d, 0x79, 0x31, 0x78,
        0xc3, 0x4b, 0xe2, 0x25, 0x6f, 0x16, 0xff, 0xf6, 0x23, 0x46, 0xff, 0x9e, 0x9b, 0x11, 0xde,
        0xc9, 0x1b, 0xc8, 0x40, 0xc6, 0xe4, 0x1d, 0xe4, 0x20, 0x67, 0xf2, 0x01, 0x0a, 0x50, 0x30,
        0xf9, 0x09, 0x9a, 0xa0, 0xc9, 0xe4, 0x13, 0x94, 0xa0, 0x64, 0xf2, 0x0b, 0xb4, 0x40, 0x8b,
        0xc9, 0x9f, 0xa0, 0x13, 0x74, 0xb2, 0xf8, 0x0b, 0x74, 0x81, 0x2e, 0x06, 0x7f, 0x83, 0x6e,
        0xd0, 0xfd, 0xed, 0x1d, 0x1d, 0x86, 0x8e, 0x7d, 0x6a, 0x42, 0x35, 0x11, 0xc3, 0xc7, 0x3e,
        0x35, 0xa1, 0x9a, 0x88, 0x21, 0x64, 0x9f, 0x9a, 0x50, 0x4d, 0xc4, 0x30, 0xb2, 0x4f, 0x4d,
        0xa8, 0x26, 0x62, 0x28, 0xd9, 0xa7, 0xe6, 0xe8, 0x96, 0x08, 0xa1, 0x84, 0x4b, 0xd3, 0x25,
        0x11, 0x42, 0xc9, 0x3e, 0x34, 0xde, 0x1d, 0x11, 0x42, 0xc9, 0xbe, 0x33, 0xd1, 0x15, 0x11,
        0x42, 0xc9, 0x3e, 0x33, 0xb3, 0x1b, 0x22, 0x84, 0x92, 0x7d, 0x65, 0xf2, 0x2d, 0xc8, 0x3f,
    ];
    const GZIP_ROWS_CRC: u32 = 0xAE78_F2E7;
}
