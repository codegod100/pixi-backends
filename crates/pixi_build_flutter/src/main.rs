mod build_script;
mod config;
mod flutter_sdk;
mod pubspec;

use build_script::{BuildMode, BuildPlatform, BuildScriptContext, Executable, SdkDownload};
use config::{FlutterBackendConfig, FlutterTarget};
use miette::IntoDiagnostic;
use pixi_build_backend::{
    Variable,
    generated_recipe::{GenerateRecipe, GeneratedRecipe, PythonParams},
    intermediate_backend::IntermediateBackendInstantiator,
    tools::BackendIdentifier,
    variants::NormalizedKey,
};
use pubspec::{Pubspec, PubspecMetadataProvider};
use rattler_build_recipe::stage0::{BinaryRelocation, Item, Script, SerializableMatchSpec, Value};
use rattler_conda_types::{ChannelUrl, PackageName, Subdir};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Directory, under pixi's cache or the work directory, that downloaded
/// Flutter SDKs are unpacked to.
const FLUTTER_SDK_DIR: &str = "flutter-sdk";

/// Parse a string into an `Item<SerializableMatchSpec>` for use in requirements.
fn matchspec_item(spec: &str) -> miette::Result<Item<SerializableMatchSpec>> {
    Ok(Item::Value(Value::new_concrete(
        spec.parse().into_diagnostic()?,
        None,
    )))
}

#[derive(Default, Clone)]
pub struct FlutterGenerator {}

impl FlutterGenerator {
    /// The desktop platform Flutter builds for on this machine.
    fn default_target(build_platform: Subdir) -> miette::Result<FlutterTarget> {
        if build_platform.is_linux() {
            Ok(FlutterTarget::Linux)
        } else if build_platform.is_osx() {
            Ok(FlutterTarget::Macos)
        } else if build_platform.is_windows() {
            Ok(FlutterTarget::Windows)
        } else {
            miette::bail!(
                "Flutter has no desktop target for {build_platform}; set `target = \"web\"` in [package.build.config]"
            )
        }
    }

    /// The commands a pure Dart package installs: the `executables` of the
    /// pubspec, or else every script in `bin/`.
    fn dart_executables(manifest_root: &Path, pubspec: &Pubspec) -> Vec<Executable> {
        if !pubspec.executables.is_empty() {
            return pubspec
                .executables
                .iter()
                .map(|(name, script)| Executable {
                    name: name.clone(),
                    script: script.clone().unwrap_or_else(|| name.clone()),
                })
                .collect();
        }

        let mut scripts: Vec<Executable> = fs_err::read_dir(manifest_root.join("bin"))
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .filter_map(|entry| {
                        let path = entry.path();
                        (path.extension()? == "dart")
                            .then(|| path.file_stem()?.to_str().map(String::from))?
                    })
                    .map(|stem| Executable {
                        name: stem.clone(),
                        script: stem,
                    })
                    .collect()
            })
            .unwrap_or_default();
        scripts.sort_by(|a, b| a.name.cmp(&b.name));
        scripts
    }
}

#[async_trait::async_trait]
impl GenerateRecipe for FlutterGenerator {
    type Config = FlutterBackendConfig;

    async fn generate_recipe(
        &self,
        model: &pixi_build_types::ProjectModel,
        config: &Self::Config,
        manifest_path: PathBuf,
        host_platform: Subdir,
        _python_params: Option<PythonParams>,
        _variants: &HashSet<NormalizedKey>,
        _channels: Vec<ChannelUrl>,
        cache_dir: Option<PathBuf>,
        _workspace_scratch_directory: Option<PathBuf>,
        _workspace_directory: Option<PathBuf>,
        _checkout_root: Option<PathBuf>,
    ) -> miette::Result<GeneratedRecipe> {
        let manifest_root = if manifest_path.is_file() {
            manifest_path
                .parent()
                .ok_or_else(|| {
                    miette::miette!("Manifest path {} has no parent", manifest_path.display())
                })?
                .to_path_buf()
        } else {
            manifest_path.clone()
        };

        let mut metadata_provider = PubspecMetadataProvider::new(&manifest_root);
        let mut generated_recipe =
            GeneratedRecipe::from_model(model.clone(), &mut metadata_provider).into_diagnostic()?;
        let pubspec = metadata_provider.pubspec().into_diagnostic()?;

        // The Flutter SDK and dart compile produce binaries for the machine
        // they run on, so the build platform decides what gets built.
        let build_platform = Subdir::current().unwrap_or(Subdir::NoArch);
        let script_platform = if build_platform.is_windows() {
            BuildPlatform::Windows
        } else {
            BuildPlatform::Unix
        };
        if host_platform != build_platform {
            miette::bail!(
                "pixi-build-flutter cannot cross-compile from {build_platform} to {host_platform}"
            );
        }

        let name = generated_recipe.recipe.package.name.to_string();
        let dart_name = pubspec.name.clone().unwrap_or_else(|| name.clone());
        let recipe = &mut generated_recipe.recipe;

        let mode = if pubspec.is_flutter() {
            BuildMode::Flutter
        } else {
            BuildMode::Dart
        };
        let target = match mode {
            BuildMode::Flutter => Some(match config.target {
                Some(target) => target,
                None => Self::default_target(build_platform)?,
            }),
            BuildMode::Dart => None,
        };

        let requirements = &mut recipe.requirements;
        let mut flutter_sdk = String::new();
        let mut sdk = None;
        let mut executables = Vec::new();
        match mode {
            BuildMode::Flutter => {
                match &config.flutter_sdk_path {
                    Some(path) => flutter_sdk = path.display().to_string(),
                    None => {
                        let archive = flutter_sdk::resolve_archive(
                            build_platform,
                            config.flutter_version.as_deref(),
                            config.flutter_sdk_url.as_deref(),
                            config.flutter_sha256.as_deref(),
                        )?;
                        // The build script downloads the SDK once into pixi's
                        // cache, keyed by the archive checksum, so that every
                        // package and workspace shares it.
                        let sdk_dir = &archive.sha256[..16];
                        flutter_sdk = match (&cache_dir, script_platform) {
                            (Some(cache), _) => cache
                                .join(FLUTTER_SDK_DIR)
                                .join(sdk_dir)
                                .display()
                                .to_string(),
                            (None, BuildPlatform::Windows) => {
                                format!("%SRC_DIR%\\.{FLUTTER_SDK_DIR}\\{sdk_dir}")
                            }
                            (None, BuildPlatform::Unix) => {
                                format!("$SRC_DIR/.{FLUTTER_SDK_DIR}/{sdk_dir}")
                            }
                        };
                        let file_name = archive
                            .url
                            .rsplit('/')
                            .next()
                            .filter(|f| !f.is_empty())
                            .unwrap_or("flutter-sdk.zip")
                            .to_string();
                        sdk = Some(SdkDownload {
                            url: archive.url,
                            sha256: archive.sha256,
                            file_name,
                        });
                        requirements.build.push(matchspec_item("curl")?);
                    }
                }

                // The flutter tool shells out to git, the script unpacks the
                // SDK with CMake, and the Linux runner is a CMake project that
                // links GTK.
                requirements.build.push(matchspec_item("git")?);
                requirements.build.push(matchspec_item("cmake")?);
                if target == Some(FlutterTarget::Linux) {
                    for spec in [
                        "ninja",
                        "pkg-config",
                        "clang",
                        "clangxx",
                        "lld",
                        "patchelf",
                        "sysroot_linux-64 >=2.17",
                    ] {
                        requirements.build.push(matchspec_item(spec)?);
                    }
                    // gtk3's pkg-config files require these modules' .pc
                    // files, which their runtime packages do not ship.
                    for spec in ["gtk3", "glib", "zlib", "expat"] {
                        requirements.host.push(matchspec_item(spec)?);
                    }
                    // The app does not link zlib or expat itself.
                    for name in ["zlib", "expat", "libzlib", "libexpat"] {
                        requirements
                            .ignore_run_exports
                            .from_package
                            .push(Item::Value(Value::new_concrete(
                                PackageName::new_unchecked(name),
                                None,
                            )));
                    }
                    requirements.run.push(matchspec_item("gtk3")?);
                }
            }
            BuildMode::Dart => {
                let dart_sdk = match pubspec
                    .dart_sdk_constraint()
                    .and_then(pubspec::pub_constraint_to_conda)
                {
                    Some(constraint) => format!("dart-sdk {constraint}"),
                    None => "dart-sdk".to_string(),
                };
                requirements.build.push(matchspec_item(&dart_sdk)?);
                executables = Self::dart_executables(&manifest_root, pubspec);
                // `dart compile exe` appends the program snapshot to the
                // runtime binary, which patchelf and install_name_tool would
                // corrupt. The binaries only link the system C library.
                recipe.build.dynamic_linking.binary_relocation =
                    BinaryRelocation::Boolean(Value::new_concrete(false, None));
            }
        }

        let build_script = BuildScriptContext {
            build_platform: script_platform,
            mode,
            target: target.map(|t| t.as_str().to_string()).unwrap_or_default(),
            source_dir: manifest_root.display().to_string(),
            flutter_sdk,
            sdk,
            name,
            dart_name,
            executables,
            extra_args: config.extra_args.clone(),
        }
        .render();

        *recipe
            .build
            .plan
            .script_mut()
            .expect("generated recipes use script mode") = Script::from_content(build_script)
            .with_env(
                config
                    .env
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::new_concrete(v.clone(), None)))
                    .collect(),
            )
            .with_secrets(model.secrets.iter().cloned().collect());

        generated_recipe
            .metadata_input_globs
            .extend(metadata_provider.input_globs());

        Ok(generated_recipe)
    }

    fn extract_input_globs_from_build(
        &self,
        config: &Self::Config,
        _workdir: impl AsRef<Path>,
        _editable: bool,
    ) -> miette::Result<Vec<String>> {
        let mut globs = BTreeSet::from(
            [
                "pubspec.yaml",
                "pubspec.lock",
                "**/*.dart",
                "assets/**",
                "linux/**",
                "macos/**",
                "windows/**",
                "web/**",
            ]
            .map(String::from),
        );
        globs.extend(config.extra_input_globs.clone());
        Ok(globs.into_iter().collect())
    }

    fn default_variants(
        &self,
        _host_platform: Subdir,
    ) -> miette::Result<BTreeMap<NormalizedKey, Vec<Variable>>> {
        Ok(BTreeMap::new())
    }
}

#[tokio::main]
pub async fn main() {
    if let Err(err) = pixi_build_backend::cli::main(|log| {
        IntermediateBackendInstantiator::<FlutterGenerator>::new(
            BackendIdentifier::new(env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION")),
            log,
            Arc::default(),
        )
    })
    .await
    {
        eprintln!("{err:?}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn project_model(name: &str) -> pixi_build_types::ProjectModel {
        serde_json::from_value(serde_json::json!({
            "name": name,
            "version": "1.0.0",
            "targets": { "defaultTarget": {} }
        }))
        .unwrap()
    }

    async fn generate(
        dir: &TempDir,
        config: &FlutterBackendConfig,
        model: pixi_build_types::ProjectModel,
    ) -> miette::Result<GeneratedRecipe> {
        FlutterGenerator::default()
            .generate_recipe(
                &model,
                config,
                dir.path().to_path_buf(),
                Subdir::current().unwrap_or(Subdir::NoArch),
                None,
                &HashSet::new(),
                vec![],
                None,
                None,
                None,
                None,
            )
            .await
    }

    fn specs(
        items: &rattler_build_recipe::stage0::ConditionalList<SerializableMatchSpec>,
    ) -> Vec<String> {
        items.iter().map(|i| i.to_string()).collect()
    }

    const FLUTTER_PUBSPEC: &str = r#"
name: my_app
description: "A new Flutter project."
version: 1.2.0+3
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
"#;

    #[tokio::test]
    async fn test_flutter_web_recipe() {
        let dir = TempDir::new().unwrap();
        fs_err::write(dir.path().join("pubspec.yaml"), FLUTTER_PUBSPEC).unwrap();
        let config = FlutterBackendConfig {
            target: Some(FlutterTarget::Web),
            flutter_sdk_path: Some(PathBuf::from("/opt/flutter")),
            ..Default::default()
        };

        let recipe = generate(&dir, &config, project_model("my-app"))
            .await
            .unwrap()
            .recipe;

        // A local SDK needs no download tools.
        assert_eq!(specs(&recipe.requirements.build), vec!["git", "cmake"]);
        assert!(recipe.requirements.host.is_empty());
        let script = recipe
            .build
            .plan
            .script()
            .unwrap()
            .content
            .as_ref()
            .unwrap();
        let script = format!("{script:?}");
        assert!(script.contains("build web --release"));
        assert!(script.contains("/opt/flutter"));
    }

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    #[tokio::test]
    async fn test_flutter_linux_recipe_downloads_sdk_into_cache() {
        let dir = TempDir::new().unwrap();
        fs_err::write(dir.path().join("pubspec.yaml"), FLUTTER_PUBSPEC).unwrap();

        let recipe = FlutterGenerator::default()
            .generate_recipe(
                &project_model("my-app"),
                &FlutterBackendConfig::default(),
                dir.path().to_path_buf(),
                Subdir::Linux64,
                None,
                &HashSet::new(),
                vec![],
                Some(PathBuf::from("/cache/pixi")),
                None,
                None,
                None,
            )
            .await
            .unwrap()
            .recipe;

        let build = specs(&recipe.requirements.build);
        for spec in ["git", "cmake", "curl", "ninja", "clangxx", "patchelf"] {
            assert!(build.contains(&spec.to_string()), "missing {spec}");
        }
        assert_eq!(
            specs(&recipe.requirements.host),
            vec!["gtk3", "glib", "zlib", "expat"]
        );
        assert_eq!(specs(&recipe.requirements.run), vec!["gtk3"]);
        assert!(recipe.source.is_empty());
        let script = format!("{:?}", recipe.build.plan.script().unwrap().content);
        assert!(script.contains("/cache/pixi/flutter-sdk/f1631b9c2c8b3529/bin/flutter"));
        assert!(script.contains("flutter_linux_3.47.6-stable.tar.xz"));
    }

    #[tokio::test]
    async fn test_metadata_comes_from_pubspec() {
        let dir = TempDir::new().unwrap();
        fs_err::write(
            dir.path().join("pubspec.yaml"),
            "name: hello_cli\nversion: 0.3.0-dev.1\ndescription: Says hello.\nhomepage: https://example.com\n",
        )
        .unwrap();
        fs_err::write(dir.path().join("LICENSE"), "MIT").unwrap();
        let model: pixi_build_types::ProjectModel =
            serde_json::from_value(serde_json::json!({ "targets": { "defaultTarget": {} } }))
                .unwrap();

        let recipe = generate(&dir, &FlutterBackendConfig::default(), model)
            .await
            .unwrap()
            .recipe;

        assert_eq!(recipe.package.name.to_string(), "hello_cli");
        assert_eq!(recipe.package.version.to_string(), "0.3.0_dev.1");
        let about = serde_json::to_value(&recipe.about).unwrap();
        assert_eq!(about["summary"], "Says hello.");
        assert_eq!(about["homepage"], "https://example.com/");
        assert_eq!(about["license_file"], serde_json::json!(["LICENSE"]));
    }

    #[tokio::test]
    async fn test_dart_cli_recipe() {
        let dir = TempDir::new().unwrap();
        fs_err::write(
            dir.path().join("pubspec.yaml"),
            "name: hello_cli\nversion: 0.1.0\nenvironment:\n  sdk: ^3.5.0\n",
        )
        .unwrap();
        fs_err::create_dir(dir.path().join("bin")).unwrap();
        fs_err::write(dir.path().join("bin/hello_cli.dart"), "void main() {}").unwrap();
        fs_err::write(dir.path().join("bin/other.dart"), "void main() {}").unwrap();

        let generated = generate(
            &dir,
            &FlutterBackendConfig::default(),
            project_model("hello_cli"),
        )
        .await
        .unwrap();
        let recipe = generated.recipe;

        assert_eq!(
            specs(&recipe.requirements.build),
            vec!["dart-sdk >=3.5.0,<4.0.0"]
        );
        let script = format!("{:?}", recipe.build.plan.script().unwrap().content);
        assert!(script.contains("bin/hello_cli.dart"));
        assert!(script.contains("bin/other.dart"));
        assert!(
            generated
                .metadata_input_globs
                .contains(&"pubspec.yaml".to_string())
        );
    }

    #[tokio::test]
    async fn test_dart_sdk_without_constraint() {
        let dir = TempDir::new().unwrap();
        fs_err::write(dir.path().join("pubspec.yaml"), "name: lib_only\n").unwrap();

        let recipe = generate(
            &dir,
            &FlutterBackendConfig::default(),
            project_model("lib_only"),
        )
        .await
        .unwrap()
        .recipe;
        assert_eq!(specs(&recipe.requirements.build), vec!["dart-sdk"]);
    }

    #[tokio::test]
    async fn test_missing_pubspec_is_an_error() {
        let dir = TempDir::new().unwrap();
        let err = generate(&dir, &FlutterBackendConfig::default(), project_model("x"))
            .await
            .err()
            .unwrap();
        assert!(format!("{err:?}").contains("pubspec.yaml"));
    }
}
