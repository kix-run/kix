//! Read a `.drv` file from the store.
//!
//! Kix reads the file itself rather than run `nix derivation show`, whose
//! JSON shape changes between Nix releases. The file is an ATerm:
//!
//! ```text
//! Derive([outputs],[input drvs],[input srcs],"system","builder",[args],[env])
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The parts of a derivation Kix reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Derivation {
    /// Each output's name and path. A fixed-output derivation also records
    /// the hash algorithm (such as `sha256`, or `r:sha256` for a NAR hash)
    /// and the expected hash in hexadecimal.
    pub outputs: BTreeMap<String, Output>,
    /// The derivations this one takes outputs from.
    pub input_drvs: Vec<PathBuf>,
    pub system: String,
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub path: PathBuf,
    pub hash_algo: String,
    pub hash: String,
}

/// A `.drv` file Kix could not read.
#[derive(Debug, thiserror::Error)]
#[error("could not read the derivation {}: {message}", path.display())]
pub struct DerivationError {
    pub path: PathBuf,
    pub message: String,
}

/// Read the derivation at the logical store path `drv`.
pub fn read(drv: &Path) -> Result<Derivation, DerivationError> {
    let fail = |message: String| DerivationError {
        path: drv.to_path_buf(),
        message,
    };
    let text =
        std::fs::read_to_string(super::store::real_path(drv)).map_err(|e| fail(e.to_string()))?;
    parse(&text).map_err(fail)
}

/// One ATerm value.
#[derive(Debug)]
enum Term {
    Str(String),
    List(Vec<Term>),
    Tuple(Vec<Term>),
}

impl Term {
    fn str(&self) -> Result<&str, String> {
        match self {
            Term::Str(s) => Ok(s),
            other => Err(format!("expected a string, found {other:?}")),
        }
    }

    fn items(&self) -> Result<&[Term], String> {
        match self {
            Term::List(items) | Term::Tuple(items) => Ok(items),
            other => Err(format!("expected a list, found {other:?}")),
        }
    }
}

fn parse(text: &str) -> Result<Derivation, String> {
    let body = text
        .strip_prefix("Derive")
        .ok_or("the file does not start with Derive")?;
    let mut parser = TermParser {
        bytes: body.as_bytes(),
        pos: 0,
    };
    let term = parser.term()?;
    let fields = term.items()?;
    let [outputs, input_drvs, _srcs, system, _builder, _args, env] = fields else {
        return Err(format!("expected 7 fields, found {}", fields.len()));
    };
    let outputs = outputs
        .items()?
        .iter()
        .map(|o| match o.items()? {
            [name, path, algo, hash] => Ok((
                name.str()?.to_string(),
                Output {
                    path: PathBuf::from(path.str()?),
                    hash_algo: algo.str()?.to_string(),
                    hash: hash.str()?.to_string(),
                },
            )),
            other => Err(format!("an output has {} fields", other.len())),
        })
        .collect::<Result<_, String>>()?;
    let input_drvs = input_drvs
        .items()?
        .iter()
        .map(|i| {
            Ok(PathBuf::from(
                i.items()?.first().ok_or("an empty input")?.str()?,
            ))
        })
        .collect::<Result<_, String>>()?;
    let env = env
        .items()?
        .iter()
        .map(|kv| match kv.items()? {
            [k, v] => Ok((k.str()?.to_string(), v.str()?.to_string())),
            other => Err(format!("an environment entry has {} fields", other.len())),
        })
        .collect::<Result<_, String>>()?;
    Ok(Derivation {
        outputs,
        input_drvs,
        system: system.str()?.to_string(),
        env,
    })
}

struct TermParser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl TermParser<'_> {
    fn term(&mut self) -> Result<Term, String> {
        match self.bytes.get(self.pos) {
            Some(b'"') => self.string().map(Term::Str),
            Some(b'[') => self.seq(b']').map(Term::List),
            Some(b'(') => self.seq(b')').map(Term::Tuple),
            other => Err(format!(
                "unexpected {:?} at byte {}",
                other.map(|b| *b as char),
                self.pos
            )),
        }
    }

    fn seq(&mut self, close: u8) -> Result<Vec<Term>, String> {
        self.pos += 1;
        let mut items = Vec::new();
        if self.bytes.get(self.pos) == Some(&close) {
            self.pos += 1;
            return Ok(items);
        }
        loop {
            items.push(self.term()?);
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b) if *b == close => {
                    self.pos += 1;
                    return Ok(items);
                }
                _ => {
                    return Err(format!(
                        "expected ',' or '{}' at byte {}",
                        close as char, self.pos
                    ));
                }
            }
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.pos += 1;
        let mut out = Vec::new();
        loop {
            let b = *self.bytes.get(self.pos).ok_or("unterminated string")?;
            self.pos += 1;
            match b {
                b'"' => break,
                b'\\' => {
                    let e = *self.bytes.get(self.pos).ok_or("unterminated escape")?;
                    self.pos += 1;
                    out.push(match e {
                        b'n' => b'\n',
                        b'r' => b'\r',
                        b't' => b'\t',
                        other => other,
                    });
                }
                other => out.push(other),
            }
        }
        String::from_utf8(out).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_derivation_reads_back() {
        let drv = parse(concat!(
            r#"Derive([("out","/nix/store/zz-chart.tgz","sha256","ab12","")"#,
            r#"],[("/nix/store/aa-dep.drv",["out"])],["/nix/store/bb-src"],"kix-helm","kix",[],"#,
            r#"[("kixHelmSpec","{\"a\":\"b\\\\c\\n\"}"),("system","kix-helm")])"#
        ));
        // The tuple above has five fields, which is malformed.
        assert!(drv.is_err());

        let drv = parse(concat!(
            r#"Derive([("out","/nix/store/zz-chart.tgz","sha256","ab12")],"#,
            r#"[("/nix/store/aa-dep.drv",["out"])],["/nix/store/bb-src"],"kix-helm","kix",[],"#,
            r#"[("kixHelmSpec","{\"a\":\"b\\\\c\\n\"}"),("system","kix-helm")])"#
        ))
        .unwrap();
        assert_eq!(drv.system, "kix-helm");
        assert_eq!(drv.input_drvs, [PathBuf::from("/nix/store/aa-dep.drv")]);
        assert_eq!(
            drv.outputs["out"],
            Output {
                path: "/nix/store/zz-chart.tgz".into(),
                hash_algo: "sha256".into(),
                hash: "ab12".into(),
            }
        );
        assert_eq!(drv.env["kixHelmSpec"], r#"{"a":"b\\c\n"}"#);
    }
}
