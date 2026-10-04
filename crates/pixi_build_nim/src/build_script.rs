use minijinja::Environment;
use serde::Serialize;

#[derive(Serialize)]
pub struct BinTarget {
    /// Module path relative to `src_dir`, without `.nim`.
    pub module: String,
    /// Name of the installed executable.
    pub name: String,
}

#[derive(Serialize)]
pub struct BuildScriptContext {
    /// The package root (where the `.nimble` file lives).
    pub source_dir: String,
    /// Absolute directory containing the Nim sources.
    pub src_dir: String,
    /// The nim command to compile with (`c`, `cpp`, `objc`).
    pub backend: String,
    pub bins: Vec<BinTarget>,
    pub is_library: bool,
    pub has_nimble_deps: bool,
    pub version: Option<String>,
    pub extra_args: Vec<String>,
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

    #[test]
    fn renders_binary_build() {
        let script = BuildScriptContext {
            source_dir: "/pkg".into(),
            src_dir: "/pkg/src".into(),
            backend: "c".into(),
            bins: vec![BinTarget {
                module: "hello".into(),
                name: "hello".into(),
            }],
            is_library: false,
            has_nimble_deps: true,
            version: Some("0.1.0".into()),
            extra_args: vec!["--opt:size".into()],
        }
        .render();
        insta::assert_snapshot!(script);
    }

    #[test]
    fn renders_library_install() {
        let script = BuildScriptContext {
            source_dir: "/pkg".into(),
            src_dir: "/pkg/src".into(),
            backend: "c".into(),
            bins: vec![],
            is_library: true,
            has_nimble_deps: false,
            version: None,
            extra_args: vec![],
        }
        .render();
        insta::assert_snapshot!(script);
    }
}
