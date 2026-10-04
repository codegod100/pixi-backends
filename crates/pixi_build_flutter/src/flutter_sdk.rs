//! Locates the Flutter SDK archive for a build.
//!
//! Flutter is not packaged on conda-forge, so the generated recipe downloads
//! the official SDK archive from Google as an extra source. rattler-build
//! requires a checksum for URL sources, so the backend ships the checksums of
//! the release it defaults to.

use rattler_conda_types::Subdir as Platform;

/// The Flutter release used when the manifest does not pick one.
pub const DEFAULT_FLUTTER_VERSION: &str = "3.47.6";

const BASE_URL: &str = "https://storage.googleapis.com/flutter_infra_release/releases";

/// sha256 of the stable archives of [`DEFAULT_FLUTTER_VERSION`], from
/// `releases_<os>.json` next to the archives.
const KNOWN_ARCHIVES: &[(Platform, &str, &str)] = &[
    (
        Platform::Linux64,
        DEFAULT_FLUTTER_VERSION,
        "f1631b9c2c8b3529323db412b0d1beacf4a748f8783b0d7cf599a8fd5f461675",
    ),
    (
        Platform::Osx64,
        DEFAULT_FLUTTER_VERSION,
        "f1f68c777b2b34153e1631670445efbeb218f42a398be32bba2051476719b0a4",
    ),
    (
        Platform::OsxArm64,
        DEFAULT_FLUTTER_VERSION,
        "a1946d3b6b3de15ce247dc89649df9035ce29e6b4e7ebe91919a25890ea2e79a",
    ),
    (
        Platform::Win64,
        DEFAULT_FLUTTER_VERSION,
        "a01bb0d26de91bc23c97cd9ccfaad281a612fb8304213fdd5df1119a09404796",
    ),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SdkArchive {
    pub url: String,
    pub sha256: String,
}

/// The URL of the stable SDK archive for `version` on `platform`.
pub fn archive_url(platform: Platform, version: &str) -> miette::Result<String> {
    let path = match platform {
        Platform::Linux64 => format!("stable/linux/flutter_linux_{version}-stable.tar.xz"),
        Platform::Osx64 => format!("stable/macos/flutter_macos_{version}-stable.zip"),
        Platform::OsxArm64 => format!("stable/macos/flutter_macos_arm64_{version}-stable.zip"),
        Platform::Win64 => format!("stable/windows/flutter_windows_{version}-stable.zip"),
        other => miette::bail!(
            "Google publishes no Flutter SDK archive for {other}; set `flutter-sdk-path` to a Flutter SDK on this machine"
        ),
    };
    Ok(format!("{BASE_URL}/{path}"))
}

/// Picks the SDK archive to download on `platform`, from the backend config.
pub fn resolve_archive(
    platform: Platform,
    version: Option<&str>,
    url: Option<&str>,
    sha256: Option<&str>,
) -> miette::Result<SdkArchive> {
    let version = version.unwrap_or(DEFAULT_FLUTTER_VERSION);
    let url = match url {
        Some(url) => url.to_string(),
        None => archive_url(platform, version)?,
    };

    let known_sha = KNOWN_ARCHIVES
        .iter()
        .find(|(p, v, _)| *p == platform && *v == version)
        .map(|(_, _, sha)| *sha);

    let sha256 = match (sha256, known_sha) {
        (Some(sha), _) => sha.to_string(),
        (None, Some(sha)) if url == archive_url(platform, version)? => sha.to_string(),
        _ => miette::bail!(
            help = format!(
                "find the sha256 of {url} in {BASE_URL}/releases_<os>.json and add it as `flutter-sha256`"
            ),
            "no checksum is known for the Flutter SDK archive {url}"
        ),
    };

    if rattler_digest::parse_digest_from_hex::<rattler_digest::Sha256>(&sha256).is_none() {
        miette::bail!("`flutter-sha256` is not a valid sha256 hex digest: {sha256}");
    }

    Ok(SdkArchive { url, sha256 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_archive_is_known_on_all_platforms() {
        for platform in [
            Platform::Linux64,
            Platform::Osx64,
            Platform::OsxArm64,
            Platform::Win64,
        ] {
            let archive = resolve_archive(platform, None, None, None).unwrap();
            assert!(archive.url.contains(DEFAULT_FLUTTER_VERSION));
        }
    }

    #[test]
    fn test_linux_arm64_has_no_archive() {
        assert!(resolve_archive(Platform::LinuxAarch64, None, None, None).is_err());
    }

    #[test]
    fn test_other_version_needs_checksum() {
        assert!(resolve_archive(Platform::Linux64, Some("3.35.0"), None, None).is_err());
        let sha = "f1631b9c2c8b3529323db412b0d1beacf4a748f8783b0d7cf599a8fd5f461675";
        let archive = resolve_archive(Platform::Linux64, Some("3.35.0"), None, Some(sha)).unwrap();
        assert_eq!(
            archive.url,
            "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.35.0-stable.tar.xz"
        );
    }

    #[test]
    fn test_custom_url_needs_checksum() {
        assert!(
            resolve_archive(
                Platform::Linux64,
                None,
                Some("https://mirror.example.com/flutter.tar.xz"),
                None
            )
            .is_err()
        );
    }
}
