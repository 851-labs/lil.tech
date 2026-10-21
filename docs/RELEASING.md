# Releasing

Apps ship as signed, notarized DMGs on GitHub Releases, and update through Sparkle. See `docs/decisions/distribution.md` for why.

## One-time setup

On the Mac that builds releases:

1. **Developer ID certificate.** "Developer ID Application: Alexandru Turcanu (WH4QW9ND3J)" must be in the login keychain. Check with:

   ```
   security find-identity -v -p codesigning
   ```

2. **Notarization profile.** Create an App Store Connect API key with the Developer role (App Store Connect › Users and Access › Integrations), then save it to the keychain:

   ```
   xcrun notarytool store-credentials lil-notary --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

3. **Sparkle signing keys.** Each app has its own, in the login keychain under the account `lil-<app>`, and backed up in 1Password as "lil <app> – Sparkle EdDSA update key". The app's public key is `SUPublicEDKey` in its `Info.plist`. lil messages uses `lil-messages`, and lil health's Mac app `lil-health` (in `LilHealth-Info.plist`). Back up a new key before releasing with it. On a new Mac, restore a key from 1Password, outside the repo:

   ```
   app=messages  # or health
   dir=$(mktemp -d) && trap 'rm -rf "$dir"' EXIT
   op item get "lil $app – Sparkle EdDSA update key" --fields "private key" --reveal | tr -d '\n' > "$dir/key"
   generate_keys --account "lil-$app" -f "$dir/key"
   generate_keys --account "lil-$app" -p   # must match SUPublicEDKey in the app's Info.plist (lil health: LilHealth-Info.plist)
   ```

   If a key is lost, a Developer ID-signed app can still move to a new one: Sparkle accepts an update that changes the EdDSA key or the Developer ID certificate, but never both in the same release. So don't rotate the certificate and the key together.

   Sparkle's tools (`generate_keys`, `sign_update`, `generate_appcast`) come with its package: `scripts/release` uses the copy in its package checkouts (`build/releases/SourcePackages/artifacts/sparkle/Sparkle/bin`), or `SPARKLE_BIN` if set. They're also in the Sparkle release archive on GitHub. The keychain asks before each copy reads a key for the first time; Always Allow skips it after that.

## Building a release

```
scripts/release messages 0.1.0
scripts/release health 0.1.0   # lil health for Mac
```

lil health for iOS goes to TestFlight instead, with `scripts/release health-ios <version>` (see [below](#lil-health-on-ios-testflight)).

This:

1. checks that the app's `SUPublicEDKey` is the public half of its signing key (`lil-<app>`), before building anything and again on the exported app (851-2692);
2. archives the app with that marketing version and a build number equal to the commit count;
3. exports it with Developer ID;
4. packages it into a DMG and signs that;
5. notarizes and staples the DMG;
6. verifies it with Gatekeeper;
7. signs the DMG for Sparkle, printing the `sparkle:edSignature` and `length` attributes for the appcast and saving them to `enclosure.txt`.

The DMG is written to `build/releases/<app>/<version>/`.

Pass `--skip-notarize` to test everything except notarization.

Don't hand out a build before it's published: its build number is the commit count, and Sparkle only offers an installed copy releases with a higher one. Debug builds have no updater.

## Publishing a release

1. **Build.** Build the notarized, Sparkle-signed DMG with `scripts/release <app> <version>` from a clean `main`. Note the build number it prints (the commit count) and the enclosure attributes in `enclosure.txt`.
2. **Create the GitHub Release.**

   ```
   git tag -a <app>/v<version> <commit> -m "lil <app> <version>"
   git push origin <app>/v<version>
   gh release create <app>/v<version> <dmg> --verify-tag --title "lil <app> <version>"
   ```

3. **Add an `<item>` to the top of `appcasts/<app>.xml`.** Set:
   - `sparkle:version` to the build number;
   - `sparkle:shortVersionString` to the version;
   - the `enclosure` to the signature and length from `enclosure.txt`.

   Merge it to `main`. Installed apps pick it up from `raw.githubusercontent.com`.

**Escape the slash in the tag.** Download URLs must spell it as `%2F`, e.g. `releases/download/messages%2Fv0.1.0/...`. GitHub returns 404 for the unescaped form, even though the API reports it.

## lil health on iOS (TestFlight)

The iOS app ships through App Store Connect. Testers get builds through TestFlight. Builds from an archive run on devices, so they talk to prod (`api.lil.tech`).

### One-time setup

1. **App ID and app record.** The App ID `tech.lil.health` needs HealthKit (with background delivery) and Sign in with Apple, which is 851-2538. Create the app in App Store Connect with that bundle ID.
2. **Xcode account.** Sign in to Xcode (Settings › Accounts) with an Apple account in team `WH4QW9ND3J` that can upload, e.g. with the App Manager role. Uploads sign and upload through it, with Apple Distribution and cloud signing. Not with an App Store Connect API key: with one, the export fails on cloud signing permissions.

### Uploading a build

From a clean tree, at the commit to ship:

```
scripts/release health-ios 0.2.0
```

This:

1. archives `LilHealthiOS` with that marketing version and a build number equal to the commit count, in its own derived data, like the Mac apps;
2. exports it for App Store Connect and uploads it, with `LilHealthiOS-ExportOptions.plist` and `-allowProvisioningUpdates`.

The archive goes to `build/releases/health-ios/<version>/`. Pass `--skip-upload` to stop after the archive, e.g. to check its version (`plutil -p build/releases/health-ios/<version>/LilHealthiOS.xcarchive/Products/Applications/lil\ health.app/Info.plist`). The script refuses to upload with uncommitted changes.

- **Use the Mac's version.** lil health's platforms share one version (`health/v<version>`), so upload with the version of the Mac release cut from the same commit. The project's `MARKETING_VERSION` is only what local builds show: releases always set it on the command line. Builds 194, 195 and 236 were uploaded without it and went out as 0.1.0 (851-2817).
- `LilHealthiOS-ExportOptions.plist` keeps Xcode from renumbering the build.
- **Export compliance** is answered in `LilHealthiOS-Info.plist`: `ITSAppUsesNonExemptEncryption` is `NO`, since the app only uses exempt encryption (HTTPS, the Keychain, SHA-256 hashes through CryptoKit). Without it, every build waits in Missing Compliance until someone answers in App Store Connect. Revisit the key if the app ever encrypts data itself.
- After App Store Connect processes the build, add it to a TestFlight group. Builds for external testers also need Beta App Review.
