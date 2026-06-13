# Store Lanes

## Apple App Store And TestFlight

Use macOS runners with Xcode installed. Product configs should declare:

- `APPSTORE_CONNECT_KEY_ID`
- `APPSTORE_CONNECT_ISSUER_ID`
- A private key path or product-specific base64 private key secret.
- `APPLE_TEAM_ID` or the product's existing team secret.

`ios` covers iPhone and iPadOS distribution. A separate `macos` or
`mac_app_store` lane is needed for Mac App Store submissions.

## Google Play

Build an `.aab`, then deploy with:

```bash
python3 -m cepheus_build.deploy.google_play \
  --aab build/app/outputs/bundle/release/app-release.aab \
  --package com.cepheuslabs.example \
  --track internal \
  --service-account "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"
```

The service account needs Android Publisher API access and permission on the
Play Console app.

Android release builds need a Play upload keystore before the `.aab` exists.
The reusable GitHub workflow materializes this only for Android matrix rows
when all four optional secrets are present:

- `ANDROID_KEYSTORE_BASE64` — base64 of the upload `.jks`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The job writes `android/upload-keystore.jks` and `android/key.properties`
inside the product app directory, then lets the product's Gradle config consume
the standard `storeFile`, `storePassword`, `keyAlias`, and `keyPassword`
properties. If none of the four secrets are present the step skips; if only
some are present it fails before building.

## Microsoft Store

Build a signed `.msix`, then deploy with:

```powershell
pwsh -NoProfile -File ../cepheus-build/scripts/submit-msstore.ps1 `
  -PackagePath build/windows/example.msix
```

Required environment:

- `PARTNER_CENTER_TENANT_ID`
- `PARTNER_CENTER_CLIENT_ID`
- `PARTNER_CENTER_CLIENT_SECRET`
- `PARTNER_CENTER_APP_ID`

The script creates a Partner Center submission, uploads the package as a zip,
and commits the submission for review.

## GitHub Releases

Products with downloadable installers attach them to a GitHub Release through
the canonical `github_release` store lane, which runs
`scripts/upload-release.sh` against the `v<version>-<build>` tag:

```bash
./bin/cepheus-build deploy -p <product> github_release
```

Do not hand-roll `gh release upload`. In CI the shared `app-release.yml`
`publish` job attaches the built installers to the tagged release (and then runs
the enabled store lanes), so a tag push performs the upload automatically. See
[`installers.md`](installers.md) for the lane definition and the release
pipeline.

## Desktop installers + package repositories

Native installers (`.dmg` / `.exe` / `.deb` / `.rpm` / Flatpak), their code
signing (Azure Trusted Signing, macOS Developer ID, GPG), the
`github_release` lane, and the self-hosted `apt_repo` / `yum_repo` /
`flatpak_repo` lanes are documented in [`installers.md`](installers.md).

