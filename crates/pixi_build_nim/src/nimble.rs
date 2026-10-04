//! A small, forgiving reader for `.nimble` package files.
//!
//! `.nimble` files are NimScript, so we cannot fully evaluate them. In
//! practice almost every package uses the declarative subset
//! (`key = "value"`, `key = @["a", "b"]` and `requires "..."`), which is
//! what we extract here. Anything we don't understand is ignored.

use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    str::FromStr,
};

use miette::Diagnostic;
use pixi_build_backend::generated_recipe::MetadataProvider;
use rattler_conda_types::{ParseVersionError, Version};

#[derive(Debug, thiserror::Error, Diagnostic)]
pub enum NimbleError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("no `.nimble` file found in {0}")]
    NotFound(PathBuf),
    #[error(
        "found multiple `.nimble` files in {dir}: {files}. Set `nimble-file` in the build config to pick one"
    )]
    Ambiguous { dir: PathBuf, files: String },
    #[error("failed to parse version from the .nimble file, {0}")]
    ParseVersion(ParseVersionError),
}

/// The parts of a `.nimble` file the backend cares about.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct NimblePackage {
    /// The file the data was read from.
    pub path: PathBuf,
    /// `packageName`, falling back to the file stem.
    pub name: String,
    pub version: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub license: Option<String>,
    /// Directory (relative to the package root) that holds the sources.
    pub src_dir: Option<String>,
    /// Directory nimble would place binaries in. Unused for installation, we
    /// install straight into `$PREFIX/bin`.
    pub bin_dir: Option<String>,
    /// Binaries to build. Each entry is a module path relative to `src_dir`
    /// without the `.nim` extension.
    pub bin: Vec<String>,
    /// `c`, `cpp`, `objc` or `js`.
    pub backend: Option<String>,
    /// Every `requires` entry, as written.
    pub requires: Vec<String>,
}

impl NimblePackage {
    /// Locate and parse the `.nimble` file in `root`.
    pub fn discover(root: &Path, explicit: Option<&Path>) -> Result<Self, NimbleError> {
        let path = match explicit {
            Some(p) => root.join(p),
            None => {
                let mut found: Vec<PathBuf> = fs_err::read_dir(root)?
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.is_file() && p.extension().is_some_and(|e| e == "nimble"))
                    .collect();
                found.sort();
                match found.len() {
                    0 => return Err(NimbleError::NotFound(root.to_path_buf())),
                    1 => found.remove(0),
                    _ => {
                        return Err(NimbleError::Ambiguous {
                            dir: root.to_path_buf(),
                            files: found
                                .iter()
                                .filter_map(|p| p.file_name())
                                .map(|n| n.to_string_lossy().into_owned())
                                .collect::<Vec<_>>()
                                .join(", "),
                        });
                    }
                }
            }
        };
        let content = fs_err::read_to_string(&path)?;
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mut pkg = Self::parse(&content, &stem);
        pkg.path = path;
        Ok(pkg)
    }

    /// Parse the textual content of a `.nimble` file.
    pub fn parse(content: &str, file_stem: &str) -> Self {
        let mut pkg = NimblePackage {
            name: file_stem.to_string(),
            ..Default::default()
        };

        // Join `requires` continuations (a trailing comma means the list
        // continues on the next line).
        let mut logical_lines = Vec::new();
        let mut current = String::new();
        for raw in content.lines() {
            let line = strip_comment(raw).trim();
            if line.is_empty() {
                continue;
            }
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(line);
            let open = current.matches(['(', '[']).count() > current.matches([')', ']']).count();
            if current.ends_with(',') || open {
                continue;
            }
            logical_lines.push(std::mem::take(&mut current));
        }
        if !current.is_empty() {
            logical_lines.push(current);
        }

        for line in logical_lines {
            if let Some(rest) = strip_keyword(&line, "requires") {
                pkg.requires.extend(string_literals(rest));
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            // Ignore `==`, `>=` etc. that aren't assignments.
            if value.starts_with('=') || key.ends_with(['<', '>', '!']) {
                continue;
            }
            let key = key.trim();
            let value = value.trim();
            let first = || string_literals(value).into_iter().next();
            match key {
                "packageName" => {
                    if let Some(v) = first() {
                        pkg.name = v;
                    }
                }
                "version" => pkg.version = first(),
                "author" => pkg.author = first(),
                "description" => pkg.description = first(),
                "license" => pkg.license = first(),
                "srcDir" => pkg.src_dir = first().filter(|s| !s.is_empty()),
                "binDir" => pkg.bin_dir = first().filter(|s| !s.is_empty()),
                "backend" => pkg.backend = first(),
                "bin" => pkg.bin = string_literals(value),
                _ => {}
            }
        }
        pkg
    }

    /// The version constraint on `nim` itself, converted to a conda
    /// matchspec fragment, if it can be expressed as one.
    pub fn nim_constraint(&self) -> Option<String> {
        self.requires
            .iter()
            .find_map(|r| {
                let r = r.trim();
                let rest = r.strip_prefix("nim")?;
                if rest.starts_with(|c: char| c.is_alphanumeric() || c == '_') {
                    return None; // e.g. `nimcrypto`
                }
                Some(rest.trim().to_string())
            })
            .and_then(|spec| nimble_spec_to_conda(&spec))
    }

    /// Whether the package depends on anything besides the compiler.
    pub fn has_nimble_dependencies(&self) -> bool {
        self.requires.iter().any(|r| {
            let name: String = r
                .trim()
                .chars()
                .take_while(|c| {
                    !c.is_whitespace() && !matches!(c, '<' | '>' | '=' | '~' | '^' | '#')
                })
                .collect();
            !name.is_empty() && name != "nim"
        })
    }
}

/// Convert a nimble version spec (`>= 2.0.0`, `>= 1.6 & < 3.0`, `== 2.2.4`)
/// into a conda version spec. Returns `None` for specs we can't translate
/// (`^=`, `~=`, `#head`, ...), in which case we leave `nim` unconstrained.
fn nimble_spec_to_conda(spec: &str) -> Option<String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    for part in spec.split('&') {
        let part = part.trim();
        let (op, ver) = ["==", ">=", "<=", ">", "<"]
            .iter()
            .find_map(|op| part.strip_prefix(op).map(|v| (*op, v.trim())))?;
        if ver.is_empty() || !ver.chars().all(|c| c.is_ascii_digit() || c == '.') {
            return None;
        }
        parts.push(format!("{op}{ver}"));
    }
    Some(parts.join(","))
}

fn strip_comment(line: &str) -> &str {
    // `#` inside a string literal is legitimate (e.g. `requires "foo#head"`).
    let mut in_str = false;
    for (i, c) in line.char_indices() {
        match c {
            '"' => in_str = !in_str,
            '#' if !in_str => return &line[..i],
            _ => {}
        }
    }
    line
}

fn strip_keyword<'a>(line: &'a str, kw: &str) -> Option<&'a str> {
    let rest = line.strip_prefix(kw)?;
    rest.starts_with([' ', '(', '"', '\t']).then_some(rest)
}

/// All double-quoted string literals in `s`, in order.
fn string_literals(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '"' {
            continue;
        }
        let mut lit = String::new();
        let mut escaped = false;
        for c in chars.by_ref() {
            if escaped {
                lit.push(c);
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                break;
            } else {
                lit.push(c);
            }
        }
        out.push(lit);
    }
    out
}

/// A [`MetadataProvider`] backed by a parsed `.nimble` file.
pub struct NimbleMetadataProvider<'a> {
    pkg: Option<&'a NimblePackage>,
}

impl<'a> NimbleMetadataProvider<'a> {
    pub fn new(pkg: Option<&'a NimblePackage>) -> Self {
        Self { pkg }
    }

    pub fn input_globs(&self, manifest_root: &Path) -> BTreeSet<String> {
        self.pkg
            .and_then(|p| p.path.strip_prefix(manifest_root).ok())
            .map(|p| p.display().to_string().replace('\\', "/"))
            .into_iter()
            .collect()
    }
}

impl MetadataProvider for NimbleMetadataProvider<'_> {
    type Error = NimbleError;

    fn name(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pkg.map(|p| p.name.to_lowercase()))
    }

    fn version(&mut self) -> Result<Option<Version>, Self::Error> {
        self.pkg
            .and_then(|p| p.version.as_deref())
            .map(|v| Version::from_str(v).map_err(NimbleError::ParseVersion))
            .transpose()
    }

    fn license(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pkg.and_then(|p| p.license.clone()))
    }

    fn summary(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pkg.and_then(|p| p.description.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
# Package

version       = "0.3.1"
author        = "Someone"
description   = "A tool # with a hash"
license       = "MIT"
srcDir        = "src"
bin           = @["hello", "tools/other"]
backend       = "c"

# Dependencies

requires "nim >= 2.0.0 & < 3.0", "cligen >= 1.7"
requires "https://github.com/foo/bar#head"

task test, "Run tests":
  exec "nim c -r tests/all"
"#;

    #[test]
    fn parses_declarative_fields() {
        let pkg = NimblePackage::parse(SAMPLE, "hello_world");
        assert_eq!(pkg.name, "hello_world");
        assert_eq!(pkg.version.as_deref(), Some("0.3.1"));
        assert_eq!(pkg.description.as_deref(), Some("A tool # with a hash"));
        assert_eq!(pkg.license.as_deref(), Some("MIT"));
        assert_eq!(pkg.src_dir.as_deref(), Some("src"));
        assert_eq!(pkg.bin, vec!["hello", "tools/other"]);
        assert_eq!(pkg.backend.as_deref(), Some("c"));
        assert_eq!(
            pkg.requires,
            vec![
                "nim >= 2.0.0 & < 3.0",
                "cligen >= 1.7",
                "https://github.com/foo/bar#head"
            ]
        );
        assert_eq!(pkg.nim_constraint().as_deref(), Some(">=2.0.0,<3.0"));
        assert!(pkg.has_nimble_dependencies());
    }

    #[test]
    fn package_name_overrides_stem_and_multiline_requires() {
        let pkg = NimblePackage::parse(
            "packageName = \"real\"\nrequires \"nim >= 1.6\",\n  \"nimcrypto\"\n",
            "stem",
        );
        assert_eq!(pkg.name, "real");
        assert_eq!(pkg.requires, vec!["nim >= 1.6", "nimcrypto"]);
        assert_eq!(pkg.nim_constraint().as_deref(), Some(">=1.6"));
    }

    #[test]
    fn nim_only_requires_has_no_deps() {
        let pkg = NimblePackage::parse("requires \"nim >= 2.0\"", "x");
        assert!(!pkg.has_nimble_dependencies());
        let pkg = NimblePackage::parse("requires \"nim ^= 2.0\"", "x");
        assert_eq!(pkg.nim_constraint(), None);
    }
}
