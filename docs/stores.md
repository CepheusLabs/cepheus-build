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

## Microsoft Store

Build a signed `.msix`, then deploy with:

```powershell
pwsh -NoProfile -File shared/cepheus-build/scripts/submit-msstore.ps1 `
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

Products with downloadable installers can use `gh release upload` from a store
lane or from their own release workflow. Deckhand is the first product config
that models this because it ships desktop installers rather than mobile-store
builds.

## Desktop installers + package repositories

Native installers (`.dmg` / `.exe` / `.deb` / `.rpm` / Flatpak), their code
signing (Azure Trusted Signing, macOS Developer ID, GPG), the
`github_release` lane, and the self-hosted `apt_repo` / `yum_repo` /
`flatpak_repo` lanes are documented in [`installers.md`](installers.md).

