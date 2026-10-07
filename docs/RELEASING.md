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

3. **Sparkle signing key.** It lives in the login keychain under the account `lil.tech`. Its public key is `SUPublicEDKey` in each app's `Info.plist`. Keep a backup of the private key:

   ```
   generate_keys --account lil.tech -x lil-tech-sparkle-private-key.txt
   ```

   Sparkle's tools (`generate_keys`, `sign_update`, `generate_appcast`) come from the Sparkle release archive on GitHub.

## Building a release

```
scripts/release messages 0.1.0
```

This:

1. archives the app with that marketing version and a build number equal to the commit count;
2. exports it with Developer ID;
3. packages it into a DMG and signs that;
4. notarizes and staples the DMG;
5. verifies it with Gatekeeper.

The DMG is written to `build/releases/<app>/<version>/`.

Pass `--skip-notarize` to test everything except notarization.
