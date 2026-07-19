// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! bundle-frb — convert `app_risk_bundle.json` into the FRB1 binary shard the
//! app parses with zero JSON cost.
//!
//! WHY: the 3.8 MB JSON risk bundle was the last large dataset decoded as
//! text on the app's cold-start path (JSONDecoder over 33k entries). Every
//! other big table (FLHH climatology, FPS1 places, FTT1 transit) already
//! ships as a validated fixed-width binary; this closes the gap. The doubles
//! are carried BIT-EXACT: Rust's `str::parse::<f64>` and Foundation's JSON
//! number parsing are both correctly rounded, so the f64 written here equals
//! the f64 JSONDecoder would have produced from the same literal — the
//! Swift-side field is byte-identical to the JSON path by construction.
//!
//! Format FRB1 (little-endian):
//!   0  magic  "FRB1"
//!   4  u32    version = 1
//!   8  u32    nFams
//!   12 u32    nZips
//!   16 u32    genLen                  (generated_utc UTF-8 byte length)
//!   20 u64    fnv1a-64 over bytes[28..]
//!   28 generated_utc bytes
//!   families:  nFams x (u8 len, bytes)
//!   zips:      nZips x 5 ASCII bytes          (sorted as in the JSON)
//!   centroids: nZips x (f64 lon, f64 lat)
//!   scores:    nZips x nFams x f64            (row-major per zip)
//!   summaries: nZips x (u16 len, bytes)       (len 0 = none)
//!   rings:     nZips x (u16 npts, npts x (f64 lon, f64 lat))  (0 = none)
//!
//! Usage: bundle-frb <in.json> <out.frb1>

use std::env;
use std::fs;
use std::process;

// ------------------------------------------------------------ tiny JSON

/// Minimal owned JSON value — just enough for the bundle's shape, pure std.
#[derive(Debug, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }
    fn as_num(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    fn as_arr(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(v) => Some(v),
            _ => None,
        }
    }
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Parser { b: text.as_bytes(), i: 0 }
    }

    fn err(&self, msg: &str) -> String {
        format!("json parse error at byte {}: {msg}", self.i)
    }

    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn eat(&mut self, c: u8, what: &str) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(self.err(what))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => self.lit("true", Json::Bool(true)),
            Some(b'f') => self.lit("false", Json::Bool(false)),
            Some(b'n') => self.lit("null", Json::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            _ => Err(self.err("expected a value")),
        }
    }

    fn lit(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(self.err("bad literal"))
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while self
            .peek()
            .map(|c| c.is_ascii_digit() || matches!(c, b'.' | b'e' | b'E' | b'+' | b'-'))
            .unwrap_or(false)
        {
            self.i += 1;
        }
        let text = std::str::from_utf8(&self.b[start..self.i]).map_err(|_| self.err("utf8"))?;
        // Correctly-rounded decimal -> f64: same result Foundation's JSON
        // number parsing produces, which is what makes FRB1 bit-exact.
        text.parse::<f64>().map(Json::Num).map_err(|_| self.err("bad number"))
    }

    fn string(&mut self) -> Result<String, String> {
        self.eat(b'"', "expected string")?;
        let mut out = String::new();
        loop {
            let c = self.peek().ok_or_else(|| self.err("unterminated string"))?;
            self.i += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let e = self.peek().ok_or_else(|| self.err("bad escape"))?;
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                // surrogate pair
                                self.eat(b'\\', "expected low surrogate")?;
                                self.eat(b'u', "expected low surrogate")?;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("bad low surrogate"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                hi
                            };
                            out.push(
                                char::from_u32(cp).ok_or_else(|| self.err("bad codepoint"))?,
                            );
                        }
                        _ => return Err(self.err("unknown escape")),
                    }
                }
                _ => {
                    // Raw UTF-8 byte run: back up and take the whole char.
                    self.i -= 1;
                    let rest = std::str::from_utf8(&self.b[self.i..])
                        .map_err(|_| self.err("utf8"))?;
                    let ch = rest.chars().next().ok_or_else(|| self.err("eof"))?;
                    out.push(ch);
                    self.i += ch.len_utf8();
                }
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, String> {
        if self.i + 4 > self.b.len() {
            return Err(self.err("short \\u"));
        }
        let s = std::str::from_utf8(&self.b[self.i..self.i + 4])
            .map_err(|_| self.err("utf8 in \\u"))?;
        self.i += 4;
        u32::from_str_radix(s, 16).map_err(|_| self.err("bad \\u"))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.eat(b'[', "expected [")?;
        let mut out = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Arr(out));
        }
        loop {
            out.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => {
                    self.i += 1;
                }
                Some(b']') => {
                    self.i += 1;
                    return Ok(Json::Arr(out));
                }
                _ => return Err(self.err("expected , or ]")),
            }
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.eat(b'{', "expected {")?;
        let mut out = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Obj(out));
        }
        loop {
            self.ws();
            let key = self.string()?;
            self.ws();
            self.eat(b':', "expected :")?;
            let val = self.value()?;
            out.push((key, val));
            self.ws();
            match self.peek() {
                Some(b',') => {
                    self.i += 1;
                }
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Json::Obj(out));
                }
                _ => return Err(self.err("expected , or }")),
            }
        }
    }
}

fn parse_json(text: &str) -> Result<Json, String> {
    let mut p = Parser::new(text);
    let v = p.value()?;
    p.ws();
    if p.i != p.b.len() {
        return Err(p.err("trailing garbage"));
    }
    Ok(v)
}

// ------------------------------------------------------------ FRB1 encode

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn encode_frb1(root: &Json) -> Result<Vec<u8>, String> {
    let generated = root
        .get("generated_utc")
        .and_then(Json::as_str)
        .ok_or("missing generated_utc")?;
    let families: Vec<&str> = root
        .get("families")
        .and_then(Json::as_arr)
        .ok_or("missing families")?
        .iter()
        .map(|f| f.as_str().ok_or("family not a string"))
        .collect::<Result<_, _>>()?;
    let zips = root.get("zips").and_then(Json::as_arr).ok_or("missing zips")?;
    let n_fams = families.len();

    // Payload = everything after the 28-byte header.
    let mut p: Vec<u8> = Vec::with_capacity(zips.len() * (5 + 16 + n_fams * 8 + 4));
    p.extend_from_slice(generated.as_bytes());
    for f in &families {
        let b = f.as_bytes();
        if b.len() > 255 {
            return Err("family name too long".into());
        }
        p.push(b.len() as u8);
        p.extend_from_slice(b);
    }
    // Section passes match the reader's layout: zips, centroids, scores,
    // summaries, rings — each a straight sequential scan.
    for z in zips {
        let code = z.get("z").and_then(Json::as_str).ok_or("entry missing z")?;
        if code.len() != 5 || !code.bytes().all(|c| c.is_ascii()) {
            return Err(format!("zip {code:?} is not 5 ASCII chars"));
        }
        p.extend_from_slice(code.as_bytes());
    }
    for z in zips {
        let c = z.get("c").and_then(Json::as_arr).ok_or("entry missing c")?;
        if c.len() < 2 {
            return Err("centroid needs [lon,lat]".into());
        }
        let lon = c[0].as_num().ok_or("lon not a number")?;
        let lat = c[1].as_num().ok_or("lat not a number")?;
        p.extend_from_slice(&lon.to_le_bytes());
        p.extend_from_slice(&lat.to_le_bytes());
    }
    for z in zips {
        let s = z.get("s").and_then(Json::as_arr).ok_or("entry missing s")?;
        if s.len() != n_fams {
            return Err(format!(
                "entry {} has {} scores for {} families",
                z.get("z").and_then(Json::as_str).unwrap_or("?"),
                s.len(),
                n_fams
            ));
        }
        for v in s {
            p.extend_from_slice(&v.as_num().ok_or("score not a number")?.to_le_bytes());
        }
    }
    for z in zips {
        let t = z.get("t").and_then(Json::as_str).unwrap_or("");
        let b = t.as_bytes();
        if b.len() > u16::MAX as usize {
            return Err("summary too long".into());
        }
        p.extend_from_slice(&(b.len() as u16).to_le_bytes());
        p.extend_from_slice(b);
    }
    for z in zips {
        match z.get("p").and_then(Json::as_arr) {
            None => p.extend_from_slice(&0u16.to_le_bytes()),
            Some(ring) => {
                if ring.len() > u16::MAX as usize {
                    return Err("ring too long".into());
                }
                p.extend_from_slice(&(ring.len() as u16).to_le_bytes());
                for pt in ring {
                    let pair = pt.as_arr().ok_or("ring point not an array")?;
                    if pair.len() < 2 {
                        return Err("ring point needs [lon,lat]".into());
                    }
                    let lon = pair[0].as_num().ok_or("ring lon")?;
                    let lat = pair[1].as_num().ok_or("ring lat")?;
                    p.extend_from_slice(&lon.to_le_bytes());
                    p.extend_from_slice(&lat.to_le_bytes());
                }
            }
        }
    }

    let mut out = Vec::with_capacity(28 + p.len());
    out.extend_from_slice(b"FRB1");
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&(n_fams as u32).to_le_bytes());
    out.extend_from_slice(&(zips.len() as u32).to_le_bytes());
    out.extend_from_slice(&(generated.len() as u32).to_le_bytes());
    out.extend_from_slice(&fnv1a64(&p).to_le_bytes());
    out.extend_from_slice(&p);
    Ok(out)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: bundle-frb <in.json> <out.frb1>");
        process::exit(2);
    }
    let text = match fs::read_to_string(&args[1]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("read {}: {e}", args[1]);
            process::exit(1);
        }
    };
    let root = match parse_json(&text) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            process::exit(1);
        }
    };
    let bytes = match encode_frb1(&root) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("encode: {e}");
            process::exit(1);
        }
    };
    // Atomic write: temp + rename, same discipline as the JSON writer.
    let tmp = format!("{}.tmp", args[2]);
    if let Err(e) = fs::write(&tmp, &bytes).and_then(|_| fs::rename(&tmp, &args[2])) {
        eprintln!("write {}: {e}", args[2]);
        process::exit(1);
    }
    let n_zips = root.get("zips").and_then(Json::as_arr).map(|z| z.len()).unwrap_or(0);
    println!("zips: {n_zips}");
    println!("bytes: {}", bytes.len());
}

// ------------------------------------------------------------ tests

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{"generated_utc":"2026-07-04T11:39:45Z",
        "families":["wind","fire"],
        "national_baseline":true,
        "zips":[
          {"z":"01001","c":[-72.6258,42.0624],"s":[0.125,0.5],"t":"windy"},
          {"z":"99999","c":[-100.5,40.25],"s":[0,0.043],
           "p":[[-100.0,40.0],[-100.1,40.1],[-100.2,40.0]]}
        ]}"#;

    #[test]
    fn json_parser_handles_bundle_shapes() {
        let v = parse_json(SAMPLE).unwrap();
        assert_eq!(v.get("generated_utc").unwrap().as_str().unwrap(), "2026-07-04T11:39:45Z");
        let zips = v.get("zips").unwrap().as_arr().unwrap();
        assert_eq!(zips.len(), 2);
        assert_eq!(zips[0].get("t").unwrap().as_str().unwrap(), "windy");
        assert_eq!(zips[1].get("p").unwrap().as_arr().unwrap().len(), 3);
        // escapes + unicode
        let esc = parse_json(r#"{"s":"a\"b\\cé😀"}"#).unwrap();
        assert_eq!(esc.get("s").unwrap().as_str().unwrap(), "a\"b\\cé😀");
    }

    #[test]
    fn frb1_layout_and_hash_round_trip() {
        let v = parse_json(SAMPLE).unwrap();
        let b = encode_frb1(&v).unwrap();
        assert_eq!(&b[0..4], b"FRB1");
        let u32at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
        let u64at = |o: usize| u64::from_le_bytes(b[o..o + 8].try_into().unwrap());
        assert_eq!(u32at(4), 1); // version
        assert_eq!(u32at(8), 2); // nFams
        assert_eq!(u32at(12), 2); // nZips
        let gen_len = u32at(16) as usize;
        assert_eq!(gen_len, "2026-07-04T11:39:45Z".len());
        assert_eq!(u64at(20), fnv1a64(&b[28..])); // stored hash matches payload
        // generated_utc then families
        let mut o = 28;
        assert_eq!(&b[o..o + gen_len], b"2026-07-04T11:39:45Z");
        o += gen_len;
        assert_eq!(b[o] as usize, 4); // "wind"
        assert_eq!(&b[o + 1..o + 5], b"wind");
        o += 5;
        assert_eq!(b[o] as usize, 4); // "fire"
        o += 5;
        // zip codes, 5 bytes each
        assert_eq!(&b[o..o + 5], b"01001");
        assert_eq!(&b[o + 5..o + 10], b"99999");
        o += 10;
        // centroid doubles are the exact parsed bits
        let f64at = |o: usize| f64::from_le_bytes(b[o..o + 8].try_into().unwrap());
        assert_eq!(f64at(o), "-72.6258".parse::<f64>().unwrap());
        assert_eq!(f64at(o + 8), "42.0624".parse::<f64>().unwrap());
        o += 32;
        // scores row-major, bit-exact
        assert_eq!(f64at(o), 0.125);
        assert_eq!(f64at(o + 8), 0.5);
        assert_eq!(f64at(o + 16), 0.0);
        assert_eq!(f64at(o + 24), "0.043".parse::<f64>().unwrap());
        o += 32;
        // summaries: "windy" then empty
        assert_eq!(u16::from_le_bytes(b[o..o + 2].try_into().unwrap()), 5);
        assert_eq!(&b[o + 2..o + 7], b"windy");
        o += 7;
        assert_eq!(u16::from_le_bytes(b[o..o + 2].try_into().unwrap()), 0);
        o += 2;
        // rings: none, then 3 points
        assert_eq!(u16::from_le_bytes(b[o..o + 2].try_into().unwrap()), 0);
        o += 2;
        assert_eq!(u16::from_le_bytes(b[o..o + 2].try_into().unwrap()), 3);
        o += 2 + 3 * 16;
        assert_eq!(o, b.len());
    }

    #[test]
    fn encode_refuses_malformed_entries() {
        // score count != family count
        let bad = r#"{"generated_utc":"x","families":["a","b"],
                      "zips":[{"z":"01001","c":[0,0],"s":[1]}]}"#;
        assert!(encode_frb1(&parse_json(bad).unwrap()).is_err());
        // zip code not 5 chars
        let bad2 = r#"{"generated_utc":"x","families":["a"],
                       "zips":[{"z":"123","c":[0,0],"s":[0]}]}"#;
        assert!(encode_frb1(&parse_json(bad2).unwrap()).is_err());
    }
}
