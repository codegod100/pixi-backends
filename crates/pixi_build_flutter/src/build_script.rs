use minijinja::Environment;
use serde::Serialize;

#[derive(Serialize)]
pub struct BuildScriptContext {
    pub build_platform: BuildPlatform,
    pub mode: BuildMode,
    /// The Flutter platform to build for (`linux`, `macos`, `windows`, `web`).
    pub target: String,
    /// The project directory, which the script copies before building.
    pub source_dir: String,
    /// Where the Flutter SDK lives during the build.
    pub flutter_sdk: String,
    /// The SDK archive to download into `flutter_sdk` when it is missing.
    pub sdk: Option<SdkDownload>,
    /// The conda package name.
    pub name: String,
    /// The Dart package name from `pubspec.yaml`.
    pub dart_name: String,
    pub executables: Vec<Executable>,
    pub extra_args: Vec<String>,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub struct SdkDownload {
    pub url: String,
    pub sha256: String,
    pub file_name: String,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub struct Executable {
    /// The name of the installed command.
    pub name: String,
    /// The script in `bin/`, without the `.dart` extension.
    pub script: String,
}

#[derive(Copy, Clone, Serialize, Debug)]
#[serde(rename_all = "kebab-case")]
pub enum BuildPlatform {
    Windows,
    Unix,
}

#[derive(Copy, Clone, Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum BuildMode {
    /// A Flutter app, built with the Flutter SDK.
    Flutter,
    /// A pure Dart package, built with `dart-sdk` from conda-forge.
    Dart,
}

impl BuildScriptContext {
    pub fn render(&self) -> String {
        let env = Environment::new();
        let template = env
            .template_from_str(include_str!("build_script.j2"))
            .unwrap();
        template.render(self).unwrap().trim().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::*;

    fn context(build_platform: BuildPlatform, mode: BuildMode, target: &str) -> BuildScriptContext {
        BuildScriptContext {
            build_platform,
            mode,
            target: target.to_string(),
            source_dir: match build_platform {
                BuildPlatform::Windows => "C:\\src\\my_app".to_string(),
                BuildPlatform::Unix => "/src/my_app".to_string(),
            },
            flutter_sdk: match build_platform {
                BuildPlatform::Windows => "C:\\cache\\flutter-sdk\\3.47.6".to_string(),
                BuildPlatform::Unix => "/cache/flutter-sdk/3.47.6".to_string(),
            },
            sdk: Some(SdkDownload {
                url: "https://example.com/flutter.zip".to_string(),
                sha256: "abc123".to_string(),
                file_name: "flutter.zip".to_string(),
            }),
            name: "my_app".to_string(),
            dart_name: "my_app".to_string(),
            executables: vec![Executable {
                name: "hello".to_string(),
                script: "main".to_string(),
            }],
            extra_args: vec!["--dart-define=FOO=bar".to_string()],
        }
    }

    #[rstest]
    #[case::linux(BuildPlatform::Unix, BuildMode::Flutter, "linux")]
    #[case::macos(BuildPlatform::Unix, BuildMode::Flutter, "macos")]
    #[case::web_unix(BuildPlatform::Unix, BuildMode::Flutter, "web")]
    #[case::windows(BuildPlatform::Windows, BuildMode::Flutter, "windows")]
    #[case::web_windows(BuildPlatform::Windows, BuildMode::Flutter, "web")]
    #[case::dart_unix(BuildPlatform::Unix, BuildMode::Dart, "")]
    #[case::dart_windows(BuildPlatform::Windows, BuildMode::Dart, "")]
    fn test_build_script(
        #[case] build_platform: BuildPlatform,
        #[case] mode: BuildMode,
        #[case] target: &str,
    ) {
        let script = context(build_platform, mode, target).render();
        let mut settings = insta::Settings::clone_current();
        settings.set_snapshot_suffix(format!("{build_platform:?}-{mode:?}-{target}"));
        settings.bind(|| {
            insta::assert_snapshot!(script);
        });
    }

    #[test]
    fn test_local_sdk_is_not_downloaded() {
        let mut ctx = context(BuildPlatform::Unix, BuildMode::Flutter, "linux");
        ctx.sdk = None;
        let script = ctx.render();
        assert!(!script.contains("curl"));
        assert!(script.contains("/cache/flutter-sdk/3.47.6/bin/flutter"));
    }

    #[test]
    fn test_dart_library_script() {
        let mut ctx = context(BuildPlatform::Unix, BuildMode::Dart, "");
        ctx.executables.clear();
        let script = ctx.render();
        assert!(script.contains("share/dart/packages/my_app"));
        assert!(!script.contains("dart compile"));
    }
}
