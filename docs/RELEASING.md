# Releasing

Apps ship as signed, notarized DMGs on GitHub Releases, and update through Sparkle. See the Distribution section of `docs/DECISIONS.md` for why.

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

   Sparkle's tools (`generate_keys`, `sign_update`, `generate_appcast`) come from the Sparkle release archive on GitHub.

## Building a release

```
scripts/release messages 0.1.0
scripts/release health 0.1.0   # lil health for Mac
```

This:

1. archives the app with that marketing version and a build number equal to the commit count;
2. exports it with Developer ID;
3. packages it into a DMG and signs that;
4. notarizes and staples the DMG;
5. verifies it with Gatekeeper.

The DMG is written to `build/releases/<app>/<version>/`.

Pass `--skip-notarize` to test everything except notarization.

Don't hand out a build before it's published: its build number is the commit count, and Sparkle only offers an installed copy releases with a higher one. Debug builds have no updater.

## Publishing a release

1. **Build.** Build the notarized DMG with `scripts/release <app> <version>` from a clean `main`. Note the build number it prints; it's the commit count.
2. **Sign for Sparkle.** Run `sign_update --account lil-<app> build/releases/<app>/<version>/<file>.dmg`. It prints the `sparkle:edSignature` and `length` attributes for the appcast.
3. **Create the GitHub Release.**

   ```
   git tag -a <app>/v<version> <commit> -m "lil <app> <version>"
   git push origin <app>/v<version>
   gh release create <app>/v<version> <dmg> --verify-tag --title "lil <app> <version>"
   ```

4. **Add an `<item>` to the top of `appcasts/<app>.xml`.** Set:
   - `sparkle:version` to the build number;
   - `sparkle:shortVersionString` to the version;
   - the `enclosure` to the signature and length from step 2.

   Merge it to `main`. Installed apps pick it up from `raw.githubusercontent.com`.

**Escape the slash in the tag.** Download URLs must spell it as `%2F`, e.g. `releases/download/messages%2Fv0.1.0/...`. GitHub returns 404 for the unescaped form, even though the API reports it.

## lil health on iOS (TestFlight)

The iOS app ships through App Store Connect. Testers get builds through TestFlight. Builds from an archive run on devices, so they talk to prod (`api.lil.tech`).

### One-time setup

1. **App ID and app record.** The App ID `tech.lil.health` needs HealthKit (with background delivery) and Sign in with Apple, which is 851-2538. Create the app in App Store Connect with that bundle ID.
2. **Upload key.** Uploads use an App Store Connect API key with the App Manager role. Keep its `.p8` in `~/.appstoreconnect/private_keys/`.

### Uploading a build

From the repo root, with a clean tree:

```
xcodebuild -workspace Lil.xcworkspace -scheme LilHealthiOS -configuration Release \
  -destination 'generic/platform=iOS' -skipMacroValidation -allowProvisioningUpdates \
  -archivePath build/LilHealthiOS.xcarchive \
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) archive

xcodebuild -exportArchive -archivePath build/LilHealthiOS.xcarchive \
  -exportOptionsPlist Apps/LilHealth/LilHealthiOS-ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  -authenticationKeyID XXXXXXXXXX -authenticationKeyIssuerID <issuer-uuid>
```

- The archive's build number is the commit count, as with the Mac apps. `LilHealthiOS-ExportOptions.plist` keeps Xcode from renumbering it.
- `LilHealthiOS-ExportOptions.plist` also exports for App Store Connect and uploads in the same step.
- After App Store Connect processes the build, add it to a TestFlight group. Builds for external testers also need Beta App Review.
