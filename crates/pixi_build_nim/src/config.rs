use std::path::{Path, PathBuf};

use indexmap::IndexMap;
use pixi_build_backend::generated_recipe::BackendConfig;
use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Deserialize, Serialize, Clone)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct NimBackendConfig {
    /// Extra args passed to every `nim c` invocation.
    #[serde(default)]
    pub extra_args: Vec<String>,
    /// Environment variables to set during the build.
    #[serde(default)]
    pub env: IndexMap<String, String>,
    /// Deprecated. Setting this has no effect; debug data is always written to
    /// the `debug` subdirectory of the work directory.
    #[serde(alias = "debug_dir")]
    pub debug_dir: Option<PathBuf>,
    /// Extra input globs to include in addition to the default ones.
    #[serde(default)]
    pub extra_input_globs: Vec<String>,
    /// List of compilers to use. Defaults to `["c"]` (or `["cxx"]` for the
    /// `cpp` nimble backend).
    pub compilers: Option<Vec<String>>,
    /// Path (relative to the package root) of the `.nimble` file to read.
    /// Only needed when the directory contains more than one.
    pub nimble_file: Option<PathBuf>,
    /// Don't read the `.nimble` file for metadata; everything must come from
    /// the pixi manifest.
    pub ignore_nimble_file: Option<bool>,
}

impl BackendConfig for NimBackendConfig {
    fn debug_dir(&self) -> Option<&Path> {
        self.debug_dir.as_deref()
    }

    /// Target-specific values override base values:
    /// - extra_args, extra_input_globs: replaced when non-empty
    /// - env: merged, target wins
    /// - compilers, nimble_file, ignore_nimble_file: replaced when set
    fn merge_with_target_config(&self, target_config: &Self) -> miette::Result<Self> {
        if target_config.debug_dir.is_some() {
            miette::bail!("`debug_dir` cannot have a target specific value");
        }

        Ok(Self {
            extra_args: if target_config.extra_args.is_empty() {
                self.extra_args.clone()
            } else {
                target_config.extra_args.clone()
            },
            env: {
                let mut merged_env = self.env.clone();
                merged_env.extend(target_config.env.clone());
                merged_env
            },
            debug_dir: self.debug_dir.clone(),
            extra_input_globs: if target_config.extra_input_globs.is_empty() {
                self.extra_input_globs.clone()
            } else {
                target_config.extra_input_globs.clone()
            },
            compilers: target_config
                .compilers
                .clone()
                .or_else(|| self.compilers.clone()),
            nimble_file: target_config
                .nimble_file
                .clone()
                .or_else(|| self.nimble_file.clone()),
            ignore_nimble_file: target_config.ignore_nimble_file.or(self.ignore_nimble_file),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserializes_from_empty() {
        serde_json::from_value::<NimBackendConfig>(serde_json::json!({})).unwrap();
    }

    #[test]
    fn merges_target_config() {
        let base = NimBackendConfig {
            extra_args: vec!["--base".into()],
            env: IndexMap::from([("A".into(), "1".into()), ("B".into(), "1".into())]),
            ..Default::default()
        };
        let target = NimBackendConfig {
            env: IndexMap::from([("B".into(), "2".into())]),
            compilers: Some(vec!["cxx".into()]),
            ..Default::default()
        };
        let merged = base.merge_with_target_config(&target).unwrap();
        assert_eq!(merged.extra_args, vec!["--base"]);
        assert_eq!(merged.env["A"], "1");
        assert_eq!(merged.env["B"], "2");
        assert_eq!(merged.compilers, Some(vec!["cxx".to_string()]));
    }
}
