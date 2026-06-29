# Releasing Any Scribe

Releases are built, **signed with Developer ID, notarized, and published as a DMG** automatically by
GitHub Actions (`.github/workflows/release.yml`) when you push a `v*` tag.

## One-time setup: add repo secrets

Settings → Secrets and variables → Actions → **New repository secret**, for each:

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Your **Developer ID Application** cert as base64 (see below). |
| `P12_PASSWORD` | Password you set when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any throwaway string (used for the CI keychain). |
| `SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` — exact string from `security find-identity -v -p codesigning`. |
| `APPLE_ID` | Your Apple ID email. |
| `APPLE_TEAM_ID` | Your 10-char Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from <https://appleid.apple.com> → Sign-In & Security → App-Specific Passwords. |

### Export the Developer ID cert to base64

In **Keychain Access**, find your *Developer ID Application* certificate, right-click → **Export** →
save as `cert.p12` (set a password = `P12_PASSWORD`). Then:

```sh
base64 -i cert.p12 | pbcopy     # paste as BUILD_CERTIFICATE_BASE64
```

Find your signing identity / Team ID:

```sh
security find-identity -v -p codesigning   # shows "Developer ID Application: Name (TEAMID)"
```

## Cut a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

Actions will: build the Metal `whisper-server`, build + sign the app (hardened runtime), bundle the
engine, create the DMG, notarize + staple it, and attach `AnyScribe-0.1.0.dmg` to a new GitHub
Release. Bump the version in the tag for each release.

## Local build (no notarization)

```sh
./make-signing-cert.sh        # once: local self-signed identity (optional)
./package-app.sh              # builds AnyScribe.app, bundling the local Metal whisper build
./make-dmg.sh                 # AnyScribe-<version>.dmg (unsigned for distribution)
```
