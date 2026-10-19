#!/usr/bin/env bash
# Patches an upstream Craft App checkout so it builds for macOS 10.12 Sierra (Intel).
# Applied at build time only, so the fork's main can follow upstream with "Sync fork".
# Usage: .github/legacy-macos/patch.sh <github-owner-of-the-forks>
set -euo pipefail
OWNER="${1:?github owner}"
MIN=10.12
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# 1. Deployment target and the bundle's minimum system version.
perl -pi -e "s/^export MACOSX_DEPLOYMENT_TARGET=.*/export MACOSX_DEPLOYMENT_TARGET=$MIN/" packaging/macos/package.sh
grep -q "MACOSX_DEPLOYMENT_TARGET=$MIN" packaging/macos/package.sh
perl -0pi -e "s#(<key>LSMinimumSystemVersion</key>\s*<string>)[^<]*(</string>)#\${1}$MIN\${2}#" packaging/macos/Info.plist.in
grep -A1 LSMinimumSystemVersion packaging/macos/Info.plist.in | grep -q "$MIN"

# 2. The launcher installs and updates from the forks, never from the official 11.0+ builds.
if [ -f crates/core/src/catalog.rs ] && grep -q 'LAUNCHER_REPO' crates/core/src/catalog.rs; then
  perl -pi -e "s#\"storytold/#\"$OWNER/#g; s#(GITHUB_OWNER: &str = )\"storytold\"#\${1}\"$OWNER\"#" crates/core/src/catalog.rs
  grep -q "GITHUB_OWNER: &str = \"$OWNER\"" crates/core/src/catalog.rs
  # The ArtCraft release feed lists the official builds: read the forks' own feed instead (one
  # file, published by .github/workflows/legacy-feed.yml), so GitHub's API isn't asked per app.
  FEED="https://github.com/$OWNER/craft-launcher/releases/download/feed/release_info.json"
  perl -pi -e "s#(pub const FEED_URL: &str = )\"[^\"]*\"#\${1}\"$FEED\"#" crates/core/src/feed.rs
  grep -q "FEED_URL: &str = \"$FEED\"" crates/core/src/feed.rs
  # That feed is made once a day and GitHub can start the job late: trust it for 36 h, not 24.
  perl -pi -e 's#^pub const MAX_AGE: i64 = 24 \* 3600;#pub const MAX_AGE: i64 = 36 * 3600;#' crates/core/src/feed.rs
  grep -q '^pub const MAX_AGE: i64 = 36 \* 3600;' crates/core/src/feed.rs
  # The fork builds are ad-hoc signed (no Developer ID), so don't require ArtCraft's team
  # signature; the download is still checked against the release's SHA-256 digest.
  perl -pi -e 's#Self \{ team: Some\(TEAM_ID\), version: release\.version\.as_ref\(\) \}#Self { team: None, version: release.version.as_ref() }#' crates/native/src/install.rs
  grep -q 'Self { team: None, version: release.version.as_ref() }' crates/native/src/install.rs
  # The fork's own version (see fork_version.sh), so the launcher's self-update sees the fork's fixes.
  if [ -n "${LEGACY_VERSION:-}" ]; then
    perl -0pi -e "s#(\[workspace\.package\]\nversion = )\"[^\"]*\"#\${1}\"$LEGACY_VERSION\"#" Cargo.toml
    grep -q "^version = \"$LEGACY_VERSION\"" Cargo.toml
    cargo metadata --format-version 1 >/dev/null # records the new version in Cargo.lock
  fi
fi
# 2b. HTTPS: the OS certificate verifier needs SecTrustEvaluateWithError (10.14+) and Sierra's root
# store is years out of date, so verify against the bundled Mozilla roots (webpki-roots) instead.
# Applies to every crate that uses ureq's platform verifier (the launcher, FilmCraft's speech models…).
changed=0
while IFS= read -r rs; do
  perl -pi -e 's#RootCerts::PlatformVerifier#RootCerts::WebPki#g' "$rs"
  changed=1
done < <(grep -rl --include='*.rs' 'RootCerts::PlatformVerifier' crates apps 2>/dev/null || true)
if [ "$changed" = 1 ]; then
  while IFS= read -r toml; do
    perl -pi -e 's#"platform-verifier"#"rustls-webpki-roots"#' "$toml"
  done < <(grep -rlE --include=Cargo.toml '^ureq *=.*"platform-verifier"' crates apps 2>/dev/null || true)
  cargo metadata --format-version 1 >/dev/null # adds webpki-roots to Cargo.lock, changing nothing else
fi

# 2c. FilmCraft: VideoToolbox's hardware decode query (VTIsHardwareDecodeSupported), HEVC calls and
# some encoder keys are macOS 10.13+; on Sierra they are NULL and touching them crashes. Below 10.13
# report no hardware codec, so decoding and export fall back to FilmCraft's own Rust codecs.
VT=crates/platform/src/videotoolbox.rs
VTE=crates/platform/src/videotoolbox_encode.rs
if [ -f "$VT" ] && grep -q 'pub fn hardware_available(codec: NalCodec) -> bool {' "$VT"; then
  perl -0pi -e 's#(pub fn hardware_available\(codec: NalCodec\) -> bool \{\n)#${1}    if !macos_at_least_10_13() {\n        return false;\n    }\n#' "$VT"
  cat >> "$VT" <<'RS'

/// Whether this Mac runs macOS 10.13 or later, where VideoToolbox has the calls this module uses
/// (macOS 10.12 build patch). Read once from SystemVersion.plist; unreadable counts as older.
pub(crate) fn macos_at_least_10_13() -> bool {
    static AT_LEAST: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *AT_LEAST.get_or_init(|| {
        let Ok(plist) = std::fs::read_to_string("/System/Library/CoreServices/SystemVersion.plist") else { return false };
        let Some(after) = plist.split("<key>ProductVersion</key>").nth(1) else { return false };
        let Some(version) = after.split("<string>").nth(1).and_then(|v| v.split("</string>").next()) else { return false };
        let mut parts = version.trim().split('.').map(|p| p.parse::<u32>().unwrap_or(0));
        let (major, minor) = (parts.next().unwrap_or(0), parts.next().unwrap_or(0));
        major > 10 || (major == 10 && minor >= 13)
    })
}
RS
  grep -q 'if !macos_at_least_10_13()' "$VT"
  if [ -f "$VTE" ]; then
    perl -0pi -e 's#(pub fn new\(config: VtConfig\) -> Result<VtEncoder, String> \{\n)#${1}        if !crate::videotoolbox::macos_at_least_10_13() {\n            return Err("hardware encoding needs macOS 10.13".into());\n        }\n#' "$VTE"
    grep -q 'hardware encoding needs macOS 10.13' "$VTE"
  fi
fi

# 3. Upstream fixes needed until they land upstream (each applies only while the bug is there).
# craft-launcher #461 added a `replace` argument to install_dmg but missed the macOS self-update call.
if [ -f crates/native/src/self_update.rs ]; then
  perl -pi -e 's#install_dmg\((&LAUNCHER, &(?:file|dmg), Some\(&existing\), None), (?!false)#install_dmg(${1}, false, #' crates/native/src/self_update.rs
fi

echo "patched for macOS $MIN (owner $OWNER)"
