# Releasing

Apps ship as signed, notarized DMGs on GitHub Releases, and update through Sparkle. See `docs/decisions/distribution.md` for why.

lil health releases from GitHub Actions ([below](#from-github-actions)). The rest of this file is the local way, which lil messages still uses and which stays the fallback for lil health.

## From GitHub Actions

The **Release** workflow (`.github/workflows/release.yml`, 851-2827) releases lil health from `main`, on the Mac minis:

```
gh workflow run release.yml -f version=0.4.0 -f target=both -f dry-run=false
```

or Actions › Release › Run workflow. The inputs:

- `version`: the marketing version, shared by the Mac and iOS apps.
- `target`: `both`, `mac` or `ios`.
- `dry-run` (on by default): build, sign and notarize the DMG, and archive and export the iOS build, but publish nothing (no tag, release, appcast branch or upload).
- `appcast-notes` (optional): what's new, as one line of HTML for the appcast item's `<description>`, like the earlier items'. Without it, add one in the appcast PR.

Each run waits for Alexandru to approve it (the `release` environment), then:

1. **mac** runs `scripts/release health <version>` headless (below): every check and step of a local release, from archive to `enclosure.txt`. The run's summary shows the build number and the enclosure.
2. **publish-mac** (not in a dry run) tags `health/v<version>` on the released commit, makes the GitHub release with the DMG, and pushes the branch `release/health-v<version>`, which adds the item to `appcasts/health.xml`. **Open its PR from the link in the run's summary**, check it, and merge it after `pr-ok` passes. The workflow can't open the PR itself: the repo doesn't let Actions open pull requests, and GitHub runs no workflows (so no `pr-ok`) for one its token opened. The release's notes are one line; write the real ones with `gh release edit health/v<version> --notes-file …`.
3. **ios** runs `scripts/release health-ios <version>` headless, which uploads to TestFlight (in a dry run, `--skip-upload`: export to disk only). It runs alongside **mac**, so one approval starts both. With `both`, it refuses a version that's already tagged, as **mac** does, but a Mac release that fails later doesn't stop the upload: rerun it with `target=mac` from the same commit, which gives it the same build number. Release iOS on its own for a version the Mac already has with `target=ios`.

Releases queue, one per platform at a time, and none is cancelled halfway. If **publish-mac** fails, rerun it (Re-run failed jobs): it picks up where it stopped, reusing the tag if it's on the same commit, and the release if it exists. Its DMG is kept for three days.

### Headless `scripts/release`

With `LIL_RELEASE_ASC_KEY_PATH` set, `scripts/release` needs nothing from the login keychain or Xcode's account:

| Variable | What |
| --- | --- |
| `LIL_RELEASE_ASC_KEY_PATH`, `LIL_RELEASE_ASC_KEY_ID`, `LIL_RELEASE_ASC_ISSUER_ID` | The "lil.tech CI" App Store Connect key: iOS provisioning profiles, cloud signing and uploads (`-authenticationKey*`), the Mac's Developer ID profile (below), and notarization (`notarytool --key`). |
| `LIL_RELEASE_KEYCHAIN` (Mac) | A keychain with one Developer ID Application identity, in the user's search list, where the export finds it. The export and the DMG are signed with it. |
| `LIL_RELEASE_SPARKLE_KEY_FILE` (Mac) | The app's Sparkle private key, as `generate_keys -x` writes it. `sign_update --ed-key-file` signs with it, and its public half is checked against `SUPublicEDKey` as the keychain's is. |

The archive is built unsigned (`CODE_SIGNING_ALLOWED=NO`), since automatic signing needs an Apple Development identity, which the minis don't have, and making one would mean a new certificate in the login keychain on every run. The script then signs it ad hoc as Xcode would: the app's entitlements with the team's prefix, the hardened runtime on the Mac, and the bundled tools' identifiers. The export replaces those signatures, with Developer ID (Mac) or cloud-managed Apple Distribution (iOS), as it replaces Apple Development's in a local release.

The Mac export signs manually, not automatically as a local release does (851-3076). Automatic signing would sign with a cloud-managed Developer ID certificate, which only the Account Holder may use, not a team key ("You haven't been given access to cloud-managed distribution certificates"). So it signs with the keychain's identity, and the provisioning profile its keychain access group needs is one of ours: `scripts/developer-id-profile.swift` finds the Developer ID profile "lil.tech CI Developer ID tech.lil.health" through the App Store Connect API, with the same key, and installs it in Xcode's profiles folder, where the job's last step removes it. If the profile is missing, invalid or lacks the keychain's certificate (a new Developer ID certificate), it deletes it and makes it again for that certificate. Xcode's own profile ("Mac Team Direct Provisioning Profile: tech.lil.health") is left to local releases. Headless releases check the archive's and the export's version and build number too (851-2817).

### Secrets

The secrets live only in the `release` environment (Settings › Environments), never at the repo level:

| Secret | What | Rotating it |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | The Developer ID Application identity (certificate and private key) as a base64 `.p12`, and its password, random from `openssl rand`. | Export just that identity, e.g. with `SecItemExport` (`security export -t identities` exports every identity in the keychain), with a new random password, and set both. A new certificate also needs the Sparkle note below. |
| `SPARKLE_HEALTH_ED_KEY` | lil health's Sparkle private key (`lil-health`), as `generate_keys --account lil-health -x <file>` writes it. | Only with a new key, through Sparkle's key rotation (One-time setup, step 3). |
| `APP_STORE_CONNECT_API_KEY_BASE64`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` | The "lil.tech CI" key (`89CC3JS2Q9`, Admin), its `.p8` base64-encoded. In 1Password, and in `~/.appstoreconnect/private_keys/` on the release Mac. | Make a new Admin team key in App Store Connect, set the three secrets, update 1Password, then revoke the old key. |

Set one by piping it in, so it never reaches a terminal or a file in the repo: `base64 -i AuthKey_….p8 | gh secret set APP_STORE_CONNECT_API_KEY_BASE64 --env release`. `gh secret list --env release` shows the names.

### The `release` environment

- **Deployable only from `main`** (a deployment branch policy), and the jobs check `github.ref` too. A fork's pull request can't use it, and gets no secrets anyway.
- **Alexandru (`pondorasti`) must approve each run**, and admins can't bypass that. Approve from the run's page, or with `gh api repos/851-labs/lil.tech/actions/runs/<id>/pending_deployments`.
- Why: the "Mac minis" runner group lets any lil.tech workflow run on them, and they're shared with Codevisor's CI.

### What stays on the minis

Nothing that signs. Each job writes the keys into its own folder under the runner's temp directory. The Mac job imports the `.p12` into a keychain it makes there, with a random password, which locks itself after the job's 90-minute timeout. Only `codesign` may use the key. The keychain goes at the front of the user's search list. The login keychain and the default keychain are never touched.

The last steps run however the job ends. They take the keychain out of the search list and delete it, delete the folder, and delete `build/releases` (the archive, the DMG, and the package checkouts). They also remove the provisioning profiles the run downloaded: only lil.tech's for that platform, so never one another job just fetched. The release's derived data is deleted as it always is. If a runner dies mid-job, its next job starts with a clean temp directory, so the only thing left is a search list entry for a keychain that no longer exists.

Each mini runs one runner, as its own macOS user (as of October 2026), so a release never shares a user with another job. The key is only as private as that user's account while the job runs.

## One-time setup

On the Mac that builds releases by hand:

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

This:

1. checks that the app's `SUPublicEDKey` is the public half of its signing key (`lil-<app>`), before building anything and again on the exported app (851-2692);
2. archives the app with that marketing version and a build number equal to the commit count;
3. exports it with Developer ID, and checks that the command line tools lil health bundles, `lil` and `lil-health`, are signed with Developer ID, the hardened runtime and a secure timestamp (851-2842, 851-2843);
4. packages it into a DMG and signs that;
5. notarizes and staples the DMG;
6. verifies it with Gatekeeper;
7. signs the DMG for Sparkle, printing the `sparkle:edSignature` and `length` attributes for the appcast and saving them to `enclosure.txt`.

The DMG is written to `build/releases/<app>/<version>/`.

Pass `--skip-notarize` to test everything except notarization.

Releases from GitHub Actions run the same script headless ([above](#headless-scriptsrelease)).

lil health for iOS goes to TestFlight instead, with `scripts/release health-ios <version>` (see [below](#lil-health-on-ios-testflight)).

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
2. **Xcode account.** Sign in to Xcode (Settings › Accounts) with an Apple account in team `WH4QW9ND3J` that can upload, e.g. with the App Manager role. Local uploads sign and upload through it, with Apple Distribution and cloud signing.
3. **API key.** For exports without Xcode's account (`-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID`), as headless releases do, use the team key "lil.tech CI" (`89CC3JS2Q9`), with the Admin role. Keep its `.p8` in `~/.appstoreconnect/private_keys/`, and back it up in 1Password. Cloud signing needs Admin: an App Manager key's export fails on cloud signing permissions, which is why "lil tech uploads" (`6VGL7L277A`) was revoked in October 2026 (851-2827).

### Uploading a build

From a clean tree, at a commit on `main` (usually the Mac release's):

```
scripts/release health-ios 0.2.0
```

This:

1. archives `LilHealthiOS` with that marketing version and a build number equal to the commit count, in its own derived data, like the Mac apps;
2. checks the archive's version and build number;
3. exports it for App Store Connect and uploads it, with `LilHealthiOS-ExportOptions.plist` and `-allowProvisioningUpdates`.

The archive goes to `build/releases/health-ios/<version>/`. Pass `--skip-upload` to export it to disk (`export/lil health.ipa`, signed the same way) instead of uploading, and check the exported version. The script refuses to upload with uncommitted changes, or from a commit that isn't on `origin/main`: pull requests are squashed, so a branch's commit count is a build number `main` reaches later with other code.

- **Use the Mac's version.** lil health's platforms share one version (`health/v<version>`), so upload with the version of the Mac release cut from the same commit. The project's `MARKETING_VERSION` is only what local builds show: releases always set it on the command line. Builds 194, 195 and 236 were uploaded without it and went out as 0.1.0 (851-2817).
- `LilHealthiOS-ExportOptions.plist` keeps Xcode from renumbering the build.
- **Export compliance** is answered in `LilHealthiOS-Info.plist`: `ITSAppUsesNonExemptEncryption` is `NO`, since the app only uses exempt encryption (HTTPS, the Keychain, SHA-256 hashes through CryptoKit). Without it, every build waits in Missing Compliance until someone answers in App Store Connect. Revisit the key if the app ever encrypts data itself.
- After App Store Connect processes the build, add it to a TestFlight group. Builds for external testers also need Beta App Review.
