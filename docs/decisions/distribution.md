# Distribution and CI

<!-- Part of docs/DECISIONS.md, the index of decisions (851-2791). -->

- **Team:** every app is signed by team `WH4QW9ND3J`. Debug builds are signed with Apple Development, so macOS keeps privacy permissions across rebuilds.
- **Versioning:** each app has its own version, shared across its platforms and tagged like `messages/v0.1.0` or `health/v0.1.0`.

## Mac apps

- **Direct download only**, never the Mac App Store. Not sandboxed.
- **Signing:** Release builds are signed with Developer ID, with the hardened runtime and a secure timestamp.
- **Notarization:** `notarytool` with an App Store Connect API key, saved in the keychain profile `lil-notary`.
- **Packaging:** a signed, notarized DMG, used both for first downloads and as the Sparkle update.
- **Updates:** Sparkle, with EdDSA-signed updates. Each app has its own key, in Alexandru's login keychain (account `lil-<app>`) and backed up in 1Password. The public key is in the app's Info.plist (for lil health, the Mac target's `LilHealth-Info.plist`). lil messages' first key was lost without a backup and replaced in October 2026 (851-2685). Installed copies still update, through Sparkle's key rotation for Developer ID-signed apps, as long as the Developer ID certificate doesn't change in the same release.
- **Releases:** GitHub Releases host the DMGs. Each app's appcast is committed to the repo (`appcasts/<app>.xml`) and served from `raw.githubusercontent.com`, because GitHub's "latest release" URL is repo-wide.
- **lil health for Mac** (851-2632) ships the same way as lil messages: `scripts/release health <version>`, tags `health/v<version>`, and `appcasts/health.xml`, which starts with no releases. Its icon is the iPhone's artwork shaped for macOS: Apple's 824-point body on a 1,024 canvas, with continuous corners and a soft shadow. Its session lives in the data protection Keychain, which needs the app's keychain access group, so the Mac app claims it (`LilHealth.entitlements`) and its releases carry a Developer ID provisioning profile, which Xcode makes and renews (`-allowProvisioningUpdates`). Without it, a Developer ID build couldn't keep its session (`errSecMissingEntitlement`), while Debug builds, with their development profile, could.

## iOS apps

- **TestFlight and the App Store**, which HealthKit requires. Release builds are signed with Apple Distribution and uploaded to App Store Connect.

## Everywhere

- **CI:** the TypeScript and Pixelbook checks run locally, before every commit, in a lefthook pre-commit hook (`lefthook.yml`, `scripts/check`), only for the parts a commit touches. The Swift checks run on GitHub, on our own Mac minis (851-2787). GitHub also deploys (`services.yml`: PR previews, then staging and prod on merge to `main`).
  - Why local at first: GitHub's Swift workflow took 6–11 minutes, mostly a cold runner restoring caches, while the same checks take about 70 seconds on a warm Mac. But the Swift checks took 2–10 minutes per commit in the hook as the package grew, longer with two worktrees checking at once.
  - **The Swift workflow** (`swift.yml`) runs `scripts/check --swift` for pull requests and pushes to `main` that touch Swift, on the self-hosted Mac minis Codevisor builds on (label `codevisor-macos-arm64`, in the "Mac minis" runner group). The group allows only codevisor and lil.tech, but any of their workflows on any ref: GitHub only lets a group allow a workflow at refs that exist, so it can't allow pull requests' (`refs/pull/<n>/merge`). Main's builds are kept apart from pull requests', and both start over past 40 GB, since the disks are Codevisor's too. They keep their builds between runs, outside the checkout (`LIL_CHECK_SCRATCH`), so a run takes minutes. It picks an Xcode with Swift 6.4 through `DEVELOPER_DIR`, never `xcode-select`, which would change the machine for Codevisor's jobs too.
  - **The repo is public:** a fork's pull request runs no workflow until a maintainer approves it (the repo's policy covers every outside contributor, not just first-timers). That approval is the barrier: a fork's PR runs its own copy of the workflows, so it could drop the job's check of the head repository, or add a workflow for the minis' label. Never approve a fork's run that changes `.github/`.
  - `check` always reports (a `changes` job decides whether it runs, and a skipped job passes), so it can become a required check.
  - The trade-off: nothing re-checks the TypeScript of a commit made with the hook skipped, or merges that combine changes. Keep commits passing, and merge only branches that are up to date with `main`.
- **No analytics or crash reporting** in the apps. The server uses Cloudflare's Workers Logs and Effect tracing, with no third-party observability.
