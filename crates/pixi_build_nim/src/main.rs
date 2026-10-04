mod build_script;
mod config;
mod nimble;

use build_script::{BinTarget, BuildScriptContext};
use config::NimBackendConfig;
use miette::IntoDiagnostic;
use nimble::{NimbleMetadataProvider, NimblePackage};
use pixi_build_backend::{
    compilers::default_compiler_variants,
    generated_recipe::{GenerateRecipe, GeneratedRecipe, PythonParams},
    intermediate_backend::IntermediateBackendInstantiator,
    tools::BackendIdentifier,
};
use rattler_build_jinja::Variable;
use rattler_build_recipe::stage0::{Item, Script, SerializableMatchSpec, Value};
use rattler_build_types::NormalizedKey;
use rattler_conda_types::{ChannelUrl, Subdir};
use std::collections::HashSet;
use std::path::PathBuf;
use std::{collections::BTreeMap, path::Path, sync::Arc};

#[derive(Default, Clone)]
pub struct NimGenerator {}

fn matchspec_item(
    spec: &str,
) -> Result<Item<SerializableMatchSpec>, rattler_conda_types::ParseMatchSpecError> {
    Ok(Item::Value(Value::new_concrete(spec.parse()?, None)))
}

#[async_trait::async_trait]
impl GenerateRecipe for NimGenerator {
    type Config = NimBackendConfig;

    async fn generate_recipe(
        &self,
        model: &pixi_build_types::ProjectModel,
        config: &Self::Config,
        manifest_path: PathBuf,
        host_platform: Subdir,
        _python_params: Option<PythonParams>,
        variants: &HashSet<NormalizedKey>,
        _channels: Vec<ChannelUrl>,
        _cache_dir: Option<PathBuf>,
        _workspace_scratch_directory: Option<PathBuf>,
        _workspace_directory: Option<PathBuf>,
        _checkout_root: Option<PathBuf>,
    ) -> miette::Result<GeneratedRecipe> {
        if host_platform.is_windows() {
            miette::bail!(
                "pixi-build-nim does not support {host_platform}: conda-forge has no `nim` package for Windows"
            );
        }

        let manifest_root = if manifest_path.is_file() {
            manifest_path
                .parent()
                .ok_or_else(|| {
                    miette::Error::msg(format!(
                        "Manifest path {} is a file but has no parent directory.",
                        manifest_path.display()
                    ))
                })?
                .to_path_buf()
        } else {
            manifest_path.clone()
        };

        // The .nimble file is required to know what to build, but can be
        // ignored for metadata.
        let nimble_pkg = NimblePackage::discover(&manifest_root, config.nimble_file.as_deref())?;
        let mut metadata = NimbleMetadataProvider::new(
            (!config.ignore_nimble_file.unwrap_or(false)).then_some(&nimble_pkg),
        );

        let mut generated_recipe =
            GeneratedRecipe::from_model(model.clone(), &mut metadata).into_diagnostic()?;

        let requirements = &mut generated_recipe.recipe.requirements;

        let backend = nimble_pkg
            .backend
            .clone()
            .unwrap_or_else(|| "c".to_string());
        if backend == "js" {
            miette::bail!("the `js` nimble backend is not supported by pixi-build-nim");
        }

        let compilers = config
            .compilers
            .clone()
            .unwrap_or_else(|| vec![if backend == "cpp" { "cxx" } else { "c" }.to_string()]);
        pixi_build_backend::compilers::add_compilers_to_requirements(
            &compilers,
            &mut requirements.build,
        );
        pixi_build_backend::compilers::add_stdlib_to_requirements(
            &compilers,
            &mut requirements.build,
            variants,
        );

        // Add the nim compiler (which ships nimble), honouring a
        // `requires "nim >= x"` from the .nimble file. A user-provided `nim`
        // build dependency intersects with this one in the solver.
        let nim_spec = match nimble_pkg.nim_constraint() {
            Some(constraint) => format!("nim {constraint}"),
            None => "nim".to_string(),
        };
        requirements
            .build
            .push(matchspec_item(&nim_spec).into_diagnostic()?);
        // Nimble shells out to git to fetch dependencies.
        if nimble_pkg.has_nimble_dependencies() {
            requirements
                .build
                .push(matchspec_item("git").into_diagnostic()?);
        }

        let src_dir = match &nimble_pkg.src_dir {
            Some(dir) => manifest_root.join(dir),
            None => manifest_root.clone(),
        };
        let bins = nimble_pkg
            .bin
            .iter()
            .map(|module| BinTarget {
                name: module.rsplit('/').next().unwrap_or(module).to_string(),
                module: module.clone(),
            })
            .collect::<Vec<_>>();

        let build_script = BuildScriptContext {
            source_dir: manifest_root.display().to_string(),
            src_dir: src_dir.display().to_string(),
            backend,
            is_library: bins.is_empty(),
            bins,
            has_nimble_deps: nimble_pkg.has_nimble_dependencies(),
            version: nimble_pkg.version.clone(),
            extra_args: config.extra_args.clone(),
        }
        .render();

        *generated_recipe
            .recipe
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
            .extend(metadata.input_globs(&manifest_root));

        Ok(generated_recipe)
    }

    fn extract_input_globs_from_build(
        &self,
        config: &Self::Config,
        _workdir: impl AsRef<Path>,
        _editable: bool,
    ) -> miette::Result<Vec<String>> {
        Ok([
            "**/*.nim",
            "**/*.nims",
            "**/*.nimble",
            "**/nim.cfg",
            "**/*.nim.cfg",
            "nimble.lock",
            "**/*.{c,h,cpp,hpp}",
        ]
        .iter()
        .map(|s| s.to_string())
        .chain(config.extra_input_globs.clone())
        .collect())
    }

    fn default_variants(
        &self,
        host_platform: Subdir,
    ) -> miette::Result<BTreeMap<NormalizedKey, Vec<Variable>>> {
        Ok(default_compiler_variants(host_platform))
    }
}

#[tokio::main]
pub async fn main() {
    if let Err(err) = pixi_build_backend::cli::main(|log| {
        IntermediateBackendInstantiator::<NimGenerator>::new(
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
    use pixi_build_types::ProjectModel;

    fn model(json: serde_json::Value) -> ProjectModel {
        serde_json::from_value(json).unwrap()
    }

    async fn generate(dir: &Path, model: ProjectModel) -> miette::Result<GeneratedRecipe> {
        NimGenerator::default()
            .generate_recipe(
                &model,
                &NimBackendConfig::default(),
                dir.to_path_buf(),
                Subdir::Linux64,
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

    #[tokio::test]
    async fn reads_metadata_and_adds_nim() {
        let dir = tempfile::tempdir().unwrap();
        fs_err::write(
            dir.path().join("hello_nim.nimble"),
            r#"version = "1.2.3"
license = "MIT"
description = "says hi"
srcDir = "src"
bin = @["hello"]
requires "nim >= 2.0.0", "cligen"
"#,
        )
        .unwrap();

        let recipe = generate(dir.path(), model(serde_json::json!({ "targets": {} })))
            .await
            .unwrap();

        insta::assert_yaml_snapshot!(recipe.recipe, {
            ".source[0].path" => "[ ... path ... ]",
            ".build.script.content" => "[ ... script ... ]",
            ".build.script" => "[ ... script ... ]",
        });
        assert!(
            recipe
                .metadata_input_globs
                .iter()
                .any(|g| g == "hello_nim.nimble")
        );
    }

    #[tokio::test]
    async fn nim_only_package_needs_no_git() {
        let dir = tempfile::tempdir().unwrap();
        fs_err::write(dir.path().join("x.nimble"), "bin = @[\"x\"]\n").unwrap();

        let recipe = generate(
            dir.path(),
            model(serde_json::json!({
                "name": "x",
                "version": "0.1.0",
                "targets": { "defaultTarget": { "buildDependencies": {
                    "nim": { "binary": { "version": "==2.2.4" } }
                }}}
            })),
        )
        .await
        .unwrap();

        let build = serde_json::to_string(&recipe.recipe.requirements.build).unwrap();
        assert!(build.contains("nim"), "{build}");
        assert!(!build.contains("git"), "{build}");
    }

    #[tokio::test]
    async fn missing_nimble_file_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let Err(err) = generate(
            dir.path(),
            model(serde_json::json!({ "name": "x", "version": "1" })),
        )
        .await
        else {
            panic!("expected an error");
        };
        assert!(err.to_string().contains("no `.nimble` file"), "{err}");
    }
}
