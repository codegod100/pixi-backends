use std::path::{Path, PathBuf};

use indexmap::IndexMap;
use pixi_build_backend::generated_recipe::BackendConfig;
use serde::{Deserialize, Serialize};

/// The platform a Flutter application is built for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FlutterTarget {
    Linux,
    Macos,
    Windows,
    Web,
}

impl FlutterTarget {
    pub fn as_str(&self) -> &'static str {
        match self {
            FlutterTarget::Linux => "linux",
            FlutterTarget::Macos => "macos",
            FlutterTarget::Windows => "windows",
            FlutterTarget::Web => "web",
        }
    }
}

#[derive(Debug, Default, Deserialize, Serialize, Clone)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub struct FlutterBackendConfig {
    /// Extra arguments passed to `flutter build <target>` (Flutter projects)
    /// or `dart compile exe` (pure Dart projects).
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

    /// What to build a Flutter app for. Defaults to the desktop platform of
    /// the build machine.
    pub target: Option<FlutterTarget>,

    /// Flutter SDK release to download. Defaults to the version this backend
    /// was released with.
    pub flutter_version: Option<String>,

    /// sha256 of the Flutter SDK archive. Required when `flutter-version` or
    /// `flutter-sdk-url` points at a release this backend does not know.
    pub flutter_sha256: Option<String>,

    /// Full URL of a Flutter SDK archive, overriding `flutter-version`.
    pub flutter_sdk_url: Option<String>,

    /// Use an existing Flutter SDK on this machine instead of downloading one.
    pub flutter_sdk_path: Option<PathBuf>,
}

impl BackendConfig for FlutterBackendConfig {
    fn debug_dir(&self) -> Option<&Path> {
        self.debug_dir.as_deref()
    }

    fn merge_with_target_config(&self, target_config: &Self) -> miette::Result<Self> {
        if target_config.debug_dir.is_some() {
            miette::bail!("`debug-dir` cannot have a target specific value");
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
            target: target_config.target.or(self.target),
            flutter_version: target_config
                .flutter_version
                .clone()
                .or_else(|| self.flutter_version.clone()),
            flutter_sha256: target_config
                .flutter_sha256
                .clone()
                .or_else(|| self.flutter_sha256.clone()),
            flutter_sdk_url: target_config
                .flutter_sdk_url
                .clone()
                .or_else(|| self.flutter_sdk_url.clone()),
            flutter_sdk_path: target_config
                .flutter_sdk_path
                .clone()
                .or_else(|| self.flutter_sdk_path.clone()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_deserialize_from_empty() {
        let config: FlutterBackendConfig = serde_json::from_value(json!({})).unwrap();
        assert!(config.extra_args.is_empty());
        assert!(config.target.is_none());
        assert!(config.flutter_version.is_none());
    }

    #[test]
    fn test_deserialize_full_config() {
        let config: FlutterBackendConfig = serde_json::from_value(json!({
            "extra-args": ["--dart-define=FOO=bar"],
            "env": {"PUB_HOSTED_URL": "https://pub.example.com"},
            "target": "web",
            "flutter-version": "3.35.0",
            "flutter-sha256": "abc",
            "flutter-sdk-path": "/opt/flutter",
        }))
        .unwrap();
        assert_eq!(config.target, Some(FlutterTarget::Web));
        assert_eq!(config.flutter_version.as_deref(), Some("3.35.0"));
        assert_eq!(config.flutter_sdk_path, Some(PathBuf::from("/opt/flutter")));
    }

    #[test]
    fn test_unknown_field_is_rejected() {
        let result: Result<FlutterBackendConfig, _> =
            serde_json::from_value(json!({"flutter-channel": "beta"}));
        assert!(result.is_err());
    }

    #[test]
    fn test_merge_with_target_config() {
        let base = FlutterBackendConfig {
            extra_args: vec!["--obfuscate".into()],
            env: IndexMap::from([("A".into(), "1".into())]),
            target: Some(FlutterTarget::Linux),
            flutter_version: Some("3.35.0".into()),
            ..Default::default()
        };
        let target = FlutterBackendConfig {
            env: IndexMap::from([("B".into(), "2".into())]),
            target: Some(FlutterTarget::Web),
            ..Default::default()
        };
        let merged = base.merge_with_target_config(&target).unwrap();
        assert_eq!(merged.extra_args, vec!["--obfuscate"]);
        assert_eq!(merged.env.len(), 2);
        assert_eq!(merged.target, Some(FlutterTarget::Web));
        assert_eq!(merged.flutter_version.as_deref(), Some("3.35.0"));
    }
}
