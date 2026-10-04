//! Reads `pubspec.yaml`, the manifest of Dart and Flutter packages.
//!
//! See <https://dart.dev/tools/pub/pubspec>.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    str::FromStr,
};

use miette::Diagnostic;
use once_cell::unsync::OnceCell;
use pixi_build_backend::generated_recipe::MetadataProvider;
use rattler_conda_types::{ParseVersionError, Version};
use serde::Deserialize;

#[derive(Debug, Default, Deserialize)]
pub struct Pubspec {
    pub name: Option<String>,
    pub version: Option<String>,
    pub description: Option<String>,
    pub homepage: Option<String>,
    pub repository: Option<String>,
    pub documentation: Option<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, serde_yaml::Value>,
    #[serde(default)]
    pub dependencies: BTreeMap<String, serde_yaml::Value>,
    /// `executables:` maps a command name to a script in `bin/` (without the
    /// `.dart` extension). A null value means the script has the same name as
    /// the command.
    #[serde(default)]
    pub executables: BTreeMap<String, Option<String>>,
}

impl Pubspec {
    /// A package is a Flutter package when it depends on the Flutter SDK.
    pub fn is_flutter(&self) -> bool {
        self.dependencies.get("flutter").is_some_and(|dep| {
            dep.get("sdk")
                .and_then(serde_yaml::Value::as_str)
                .is_some_and(|sdk| sdk == "flutter")
        })
    }

    /// The Dart SDK constraint from `environment.sdk`.
    pub fn dart_sdk_constraint(&self) -> Option<&str> {
        self.environment
            .get("sdk")
            .and_then(serde_yaml::Value::as_str)
    }
}

#[derive(Debug, thiserror::Error, Diagnostic)]
pub enum MetadataError {
    #[error("failed to read {}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to parse {}", path.display())]
    Yaml {
        path: PathBuf,
        #[source]
        source: serde_yaml::Error,
    },
    #[error("failed to parse the pubspec version '{version}' as a conda version")]
    Version {
        version: String,
        #[source]
        source: ParseVersionError,
    },
}

/// Supplies package metadata from `pubspec.yaml` for anything the pixi
/// manifest leaves out.
pub struct PubspecMetadataProvider {
    manifest_root: PathBuf,
    pubspec: OnceCell<Pubspec>,
}

impl PubspecMetadataProvider {
    pub fn new(manifest_root: impl AsRef<Path>) -> Self {
        Self {
            manifest_root: manifest_root.as_ref().to_path_buf(),
            pubspec: OnceCell::new(),
        }
    }

    pub fn pubspec(&self) -> Result<&Pubspec, MetadataError> {
        self.pubspec.get_or_try_init(|| {
            let path = self.manifest_root.join("pubspec.yaml");
            let contents = fs_err::read_to_string(&path).map_err(|source| MetadataError::Io {
                path: path.clone(),
                source,
            })?;
            serde_yaml::from_str(&contents).map_err(|source| MetadataError::Yaml { path, source })
        })
    }

    /// The pubspec influences the generated recipe, so changes to it must
    /// trigger regenerating the recipe.
    pub fn input_globs(&self) -> Vec<String> {
        vec!["pubspec.yaml".to_string()]
    }
}

impl MetadataProvider for PubspecMetadataProvider {
    type Error = MetadataError;

    fn name(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pubspec()?.name.as_ref().map(|n| n.to_lowercase()))
    }

    fn version(&mut self) -> Result<Option<Version>, Self::Error> {
        match &self.pubspec()?.version {
            Some(version) => Ok(Some(pub_version_to_conda(version)?)),
            None => Ok(None),
        }
    }

    fn description(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pubspec()?.description.clone())
    }

    fn summary(&mut self) -> Result<Option<String>, Self::Error> {
        // pub descriptions are one or two sentences, which fits a summary.
        Ok(self.pubspec()?.description.clone())
    }

    fn homepage(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pubspec()?.homepage.clone())
    }

    fn repository(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pubspec()?.repository.clone())
    }

    fn documentation(&mut self) -> Result<Option<String>, Self::Error> {
        Ok(self.pubspec()?.documentation.clone())
    }

    fn license_files(&mut self) -> Result<Option<Vec<String>>, Self::Error> {
        // pubspec has no license field, but pub requires a LICENSE file for
        // published packages.
        let files: Vec<String> = ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]
            .into_iter()
            .filter(|f| self.manifest_root.join(f).is_file())
            .map(String::from)
            .collect();
        Ok((!files.is_empty()).then_some(files))
    }
}

/// Converts a pub (semver) version to a conda version.
///
/// Semver pre-release tags (`1.0.0-dev.1`) use `-`, which conda does not
/// allow, so it becomes `_`. Build metadata (`1.0.0+1`) maps to a conda local
/// version.
pub fn pub_version_to_conda(version: &str) -> Result<Version, MetadataError> {
    let converted = version.trim().replace('-', "_");
    Version::from_str(&converted).map_err(|source| MetadataError::Version {
        version: version.to_string(),
        source,
    })
}

/// Converts a pub version constraint to a conda version spec.
///
/// Handles `any`, exact versions, caret constraints (`^3.5.0`) and ranges
/// (`>=3.0.0 <4.0.0`). Returns `None` when the constraint does not restrict
/// anything.
pub fn pub_constraint_to_conda(constraint: &str) -> Option<String> {
    let constraint = constraint.trim().trim_matches(|c| c == '"' || c == '\'');
    if constraint.is_empty() || constraint == "any" {
        return None;
    }

    if let Some(base) = constraint.strip_prefix('^') {
        let base = base.trim();
        let parts: Vec<u64> = base
            .split(['.', '-', '+'])
            .take(3)
            .map(|p| p.parse().unwrap_or(0))
            .collect();
        let (major, minor, patch) = (
            parts.first().copied().unwrap_or(0),
            parts.get(1).copied().unwrap_or(0),
            parts.get(2).copied().unwrap_or(0),
        );
        // Caret allows changes that do not modify the left-most non-zero
        // component, like Cargo.
        let upper = if major > 0 {
            format!("{}.0.0", major + 1)
        } else if minor > 0 {
            format!("0.{}.0", minor + 1)
        } else {
            format!("0.0.{}", patch + 1)
        };
        return Some(format!(">={},<{upper}", base.replace('-', "_")));
    }

    let parts: Vec<String> = constraint
        .split_whitespace()
        .map(|part| part.replace('-', "_"))
        .collect();
    if parts.len() == 1 && parts[0].starts_with(|c: char| c.is_ascii_digit()) {
        return Some(format!("=={}", parts[0]));
    }
    Some(parts.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::rstest;

    #[rstest]
    #[case("^3.5.0", Some(">=3.5.0,<4.0.0"))]
    #[case("^0.2.3", Some(">=0.2.3,<0.3.0"))]
    #[case("^0.0.3", Some(">=0.0.3,<0.0.4"))]
    #[case(">=3.0.0 <4.0.0", Some(">=3.0.0,<4.0.0"))]
    #[case("'>=2.17.0 <3.0.0'", Some(">=2.17.0,<3.0.0"))]
    #[case("3.4.0", Some("==3.4.0"))]
    #[case("^3.6.0-0", Some(">=3.6.0_0,<4.0.0"))]
    #[case("any", None)]
    fn test_pub_constraint_to_conda(#[case] input: &str, #[case] expected: Option<&str>) {
        assert_eq!(pub_constraint_to_conda(input).as_deref(), expected);
    }

    #[rstest]
    #[case("1.0.0", "1.0.0")]
    #[case("1.0.0+1", "1.0.0+1")]
    #[case("2.1.0-dev.3", "2.1.0_dev.3")]
    fn test_pub_version_to_conda(#[case] input: &str, #[case] expected: &str) {
        assert_eq!(pub_version_to_conda(input).unwrap().to_string(), expected);
    }

    #[test]
    fn test_parse_flutter_pubspec() {
        let pubspec: Pubspec = serde_yaml::from_str(
            r#"
name: my_app
description: "A new Flutter project."
publish_to: 'none'
version: 1.0.0+1
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
"#,
        )
        .unwrap();
        assert!(pubspec.is_flutter());
        assert_eq!(pubspec.dart_sdk_constraint(), Some("^3.9.0"));
    }

    #[test]
    fn test_parse_dart_pubspec_with_executables() {
        let pubspec: Pubspec = serde_yaml::from_str(
            r#"
name: hello_cli
version: 0.1.0
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  args: ^2.4.0
executables:
  hello:
  hello-world: main
"#,
        )
        .unwrap();
        assert!(!pubspec.is_flutter());
        assert_eq!(pubspec.executables.get("hello"), Some(&None));
        assert_eq!(
            pubspec.executables.get("hello-world"),
            Some(&Some("main".to_string()))
        );
    }
}
