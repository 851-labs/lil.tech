# Decisions

## Repo

- **Monorepo:** lil.tech holds all our apps, written in Swift. Lil Messages comes first, then Lil Mail, Lil Browser, and others.
- **Open source:** Apache 2.0. Real user data (e.g. `chat.db`) is never committed. Test fixtures are synthetic.
- **Layout:**
  - `Lil.xcworkspace`
  - Thin app projects under `Apps/`
  - One SPM package with many small modules
  - Code moves into a shared module once a second app needs it, not before (e.g. a ⌘K command palette)
- **Bundle IDs:** `tech.lil.messages`, `tech.lil.mail`, and so on.
- **Formatting:** swift-format with 2-space indents, enforced in CI.
- **Branching:** trunk-based, with short-lived PRs into `main`.

## Platform and language

- **Platforms:** macOS only for now, with a minimum of macOS 26. No Perception needed.
  - Some future lil apps may also ship on iOS, but Lil Messages won't.
  - Shared modules should avoid AppKit where it's cheap to do so.
- **Swift:** latest toolchain (Swift 6.4, Xcode 27), Swift 6 language mode with complete strict concurrency, on every target.
  - All upcoming Swift 7 features are on: `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`, `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, `ImmutableWeakCaptures`.
  - CI treats warnings as errors, for our own targets only (warnings from third-party packages don't count). Warnings stay warnings locally.
  - Default actor isolation stays `nonisolated` for now. TCA 1.x's `@Reducer` macro breaks under `MainActor` default isolation ([#3768](https://github.com/pointfreeco/swift-composable-architecture/issues/3768)). Revisit with TCA 2.0, which fully supports it.
- **Localization:** English only for now.

## Architecture

- **Architecture:** the Point-Free Way (pfw).
- **State management:** [TCA](https://github.com/pointfreeco/swift-composable-architecture) 1.26, with the `ComposableArchitecture2Deprecations` trait enabled. Move to TCA 2.0 once it's publicly released.
- **Libraries:**
  - Any pointfreeco package can be added whenever it's useful, without a separate decision.
  - Core set: Dependencies, SQLiteData + StructuredQueries, Sharing, SwiftNavigation, Tagged (typed IDs), IssueReporting, CustomDump, Swift Testing, SnapshotTesting.
- **Look and feel:** stock Apple. System controls, fonts, colors, SF Symbols and Liquid Glass. No custom design system.
- **UI:** SwiftUI for the app shell and all navigation (split view, sheets, settings, toolbar, windows).
  - AppKit only for leaf views where performance or control matters, e.g. the message list (`NSTableView`/`NSCollectionView`) and the composer (`NSTextView`).
  - Wrap AppKit views in `NSViewRepresentable` and pass the store in. AppKit code uses only `observe { }` and `store.send`, never navigation.

## Distribution

- **Direct download only**, never the Mac App Store. Not sandboxed.
- **Signing:** team `WH4QW9ND3J`.
  - Debug builds are signed with Apple Development, so macOS keeps privacy permissions across rebuilds.
  - Release builds are signed with Developer ID, with the hardened runtime and a secure timestamp.
- **Notarization:** `notarytool` with an App Store Connect API key, saved in the keychain profile `lil-notary`.
- **Packaging:** a signed, notarized DMG, used both for first downloads and as the Sparkle update.
- **Updates:** Sparkle, with EdDSA-signed updates. The private key lives only in Alexandru's login keychain (backed up); the public key is in the app's Info.plist.
- **Releases:** GitHub Releases host the DMGs. Each app's appcast is committed to the repo (`appcasts/<app>.xml`) and served from `raw.githubusercontent.com`, because GitHub's "latest release" URL is repo-wide.
- **Versioning:** each app has its own version, tagged like `messages/v0.1.0`.
- **CI:** a self-hosted macOS runner, once we need one.
- **No analytics or crash reporting.**

## Lil Messages

- **What it is:** an iMessage client and a front end to Messages.app. Messages.app stays signed in and does the actual sending and receiving.
  - No unified inbox for now.
  - No messaging service of our own.
- **Reading:** query `~/Library/Messages/chat.db` directly, read-only. This requires Full Disk Access.
- **Our own data:** a SQLiteData database only for app-specific state like pins, drafts and settings. A search index can come later.
- **Detecting changes:** watch `chat.db` and its WAL file for writes, then re-run the active queries.
- **Sending:** script Messages.app with AppleScript, which requires the Automation permission.
  - Text and files are supported.
  - Tapbacks, replies and edits aren't supported in v1, because they'd need private frameworks and disabling SIP.
- **Notifications:** left to Messages.app in v1.
- **Contact names:** resolved through the Contacts framework, which requires the Contacts permission.
- **Onboarding:** a first-launch flow that walks through granting Full Disk Access, Automation and Contacts.

## Open questions

- What "lil" means as a product idea, and what v1 of Lil Messages includes.

## Notes

- `chat.db` is in WAL mode, so we can read it live while Messages.app writes to it.
- Some message text lives only in `attributedBody`, an `NSAttributedString` archived in the legacy typedstream format, not in `text`. `AttributedBody.text(from:)` reads just the string payload in pure Swift, instead of using the deprecated, non-secure `NSUnarchiver`. It matched `NSUnarchiver` on all ~70k blobs in a real `chat.db` and runs about 20× faster.
- `attributedBody` is the more complete source of text. `text` sometimes omits leading content (e.g. mentions), and differs by U+FFFC attachment placeholders.
