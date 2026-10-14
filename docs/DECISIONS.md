# Decisions

## Repo

- **Monorepo:** lil.tech holds all our apps and the API they share. Apps are written in Swift, the server in TypeScript. lil messages came first (now paused), then lil health, then lil mail, lil calendar, lil browser, and others.
- **Naming:** app names are lowercase everywhere users see them, even at the start of a sentence: "lil messages", "lil mail". Code identifiers keep Swift casing (`LilMessages`).
- **Open source:** Apache 2.0. Real user data (e.g. `chat.db`, Health data) is never committed. Test fixtures are synthetic.
- **Layout:**
  - `Lil.xcworkspace`
  - Thin app projects under `Apps/`
  - One SPM package with many small modules
  - Server code in a TypeScript workspace under `Services/`
  - Code moves into a shared module once a second app needs it, not before (e.g. a ⌘K command palette)
- **Bundle IDs:** `tech.lil.messages`, `tech.lil.mail`, and so on. An app that ships on several platforms uses one App ID for all of them (e.g. `tech.lil.health` on iOS and macOS).
- **Formatting:** swift-format with 2-space indents for Swift, and Vite+'s formatter and linter (Oxfmt, Oxlint) for TypeScript, enforced in CI.
- **Branching:** trunk-based, with short-lived PRs into `main`.
- **Tickets:** every app stays in the Linear project lil.tech, told apart by labels (`lil health`, `api`, …).

## Platform and language

- **Platforms:** macOS 26 and later. No Perception needed.
  - lil health also ships on iOS, with a minimum of iOS 26. lil messages stays macOS-only.
  - Shared modules should avoid AppKit where it's cheap to do so.
- **Swift:** latest toolchain (Swift 6.4, Xcode 27), Swift 6 language mode with complete strict concurrency, on every target.
  - All upcoming Swift 7 features are on: `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`, `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, `ImmutableWeakCaptures`.
  - CI treats warnings as errors, for our own targets only (warnings from third-party packages don't count). Warnings stay warnings locally.
  - Default actor isolation stays `nonisolated` for now. TCA 1.x's `@Reducer` macro breaks under `MainActor` default isolation ([#3768](https://github.com/pointfreeco/swift-composable-architecture/issues/3768)). Revisit with TCA 2.0, which fully supports it.
- **TypeScript:** server code uses [Effect](https://effect.website) 4 with strict TypeScript, and the [Vite+](https://viteplus.dev) toolchain (`vp check`, `vp test`).
- **Localization:** English only for now.

## Architecture

- **Architecture:** the Point-Free Way (pfw).
- **State management:** [TCA](https://github.com/pointfreeco/swift-composable-architecture) 1.26, with the `ComposableArchitecture2Deprecations` trait enabled. Move to TCA 2.0 once it's publicly released.
- **Libraries:**
  - Any pointfreeco package can be added whenever it's useful, without a separate decision.
  - Core set: Dependencies, SQLiteData + StructuredQueries, Sharing, SwiftNavigation, Tagged (typed IDs), IssueReporting, CustomDump, Swift Testing, SnapshotTesting.
- **Look and feel:** stock Apple. System controls, fonts, colors, SF Symbols and Liquid Glass. No custom design system.
  - Exception: lil health is a close visual clone of iPad Health (cards, category colors and icons), because that's its reference.
- **UI:** SwiftUI for the app shell and all navigation (split view, sheets, settings, toolbar, windows).
  - AppKit only for leaf views where performance or control matters, e.g. the message list (`NSTableView`/`NSCollectionView`) and the composer (`NSTextView`).
  - Wrap AppKit views in `NSViewRepresentable` and pass the store in. AppKit code uses only `observe { }` and `store.send`, never navigation.

## Distribution

- **Team:** every app is signed by team `WH4QW9ND3J`. Debug builds are signed with Apple Development, so macOS keeps privacy permissions across rebuilds.
- **Versioning:** each app has its own version, shared across its platforms and tagged like `messages/v0.1.0` or `health/v0.1.0`.

### Mac apps

- **Direct download only**, never the Mac App Store. Not sandboxed.
- **Signing:** Release builds are signed with Developer ID, with the hardened runtime and a secure timestamp.
- **Notarization:** `notarytool` with an App Store Connect API key, saved in the keychain profile `lil-notary`.
- **Packaging:** a signed, notarized DMG, used both for first downloads and as the Sparkle update.
- **Updates:** Sparkle, with EdDSA-signed updates. The private key lives only in Alexandru's login keychain (backed up); the public key is in the app's Info.plist.
- **Releases:** GitHub Releases host the DMGs. Each app's appcast is committed to the repo (`appcasts/<app>.xml`) and served from `raw.githubusercontent.com`, because GitHub's "latest release" URL is repo-wide.

### iOS apps

- **TestFlight and the App Store**, which HealthKit requires. Release builds are signed with Apple Distribution and uploaded to App Store Connect.

### Everywhere

- **CI:** a self-hosted macOS runner for Swift, once we need one. TypeScript CI runs on GitHub-hosted runners.
- **No analytics or crash reporting** in the apps. The server uses Cloudflare's Workers Logs and Effect tracing, with no third-party observability.

## Server

- **One API for every app:** a monolith at `api.lil.tech`, used by lil health now and by lil mail and lil calendar later.
  - Environments: prod (`api.lil.tech`), staging (`api.staging.lil.tech`), and a preview per PR.
  - Staging and previews hold synthetic data only. Simulator builds use them; builds on your own iPhone, with your real Health data, use prod under your own account.
- **Hosting:** Cloudflare only for now, on Workers Paid. `lil.tech` is registered at Namecheap, with DNS on Cloudflare.
- **Stack:** Effect 4, Vite+, and [Alchemy](https://alchemy.run) v2 for infrastructure as code (`alchemy.run.ts`).
- **API contract:** Effect HttpApi publishes OpenAPI, with routes versioned under `/v1`. The spec is committed, and the Swift client is generated from it with `swift-openapi-generator`.
- **Storage:**
  - D1 holds data shared across users: users, identities, sessions, devices and connections.
  - IDs are a type prefix plus a 26-character time-sortable code (e.g. `usr_01jb…`), with branded Effect Schema types. Times are Unix milliseconds.
  - Each user's own data (health now, mail and calendar later) lives in that user's SQLite-backed Durable Object.
  - Large blobs (ECG voltages, workout routes, sync snapshots) live in R2.
  - R2 blobs are immutable and addressed by content hash. They're only deleted with a grace period (or when an account is deleted), and snapshots can be rebuilt from the Durable Object.
  - Not D1 for user data, because one D1 database has a hard 10 GB cap shared by everyone, and a Worker can't bind a new database per user at runtime.
- **Backups:** D1 and Durable Object point-in-time recovery (30 days). R2 has none, which is why blobs are immutable.

## Accounts

- **Auth:** our own, written in Effect. Sign in with Apple and Sign in with Google.
  - The apps sign in natively. The server verifies the provider's ID token and issues its own session: short-lived access tokens and rotating refresh tokens.
  - **Access tokens:** 15-minute HS256 JWTs carrying the user, device and session. They're verified without a database read, so signing out takes up to 15 minutes to reach them. Each stage has its own signing key, generated and kept by Alchemy.
  - **Refresh tokens:** opaque and random, stored only as SHA-256 hashes. Each one works once: refreshing returns a new pair and revokes the old token. A refresh token expires 90 days after it was issued, so a device that opens the app at least every 90 days stays signed in.
  - **Reuse ends the session.** Presenting an already-used refresh token revokes every token descended from the same sign-in, since only a stolen copy (or a retried request whose response was lost) would do that. The app then signs in again. There's no grace period.
  - Signing out revokes the device's session. Deleting a device or user deletes its sessions.
- **Identities and connections are separate:**
  - An identity is a way to sign in. Signing in with Google requests identity scopes only.
  - A connection is a data source the user grants access to, with its own scopes, credentials and sync state: Apple Health now, Gmail, IMAP and calendars later.
- **Account linking:** never automatic by email. A signed-in user links another sign-in method explicitly.
- **Deletion and export:** users can delete their account and export their data from inside the apps.

## Sync

- **Local-first:** apps keep a local SQLite copy of the user's data and query only that. Derived values (e.g. daily totals) are computed locally.
- **Change log:** every write to a user's data appends to their change log, with a sequence number that increases per user and has no gaps. Clients pull changes after their cursor, bootstrap new devices from snapshots, and get live notices over a WebSocket.
- **Generic:** the protocol isn't specific to health, so lil mail and lil calendar can reuse it. It's specified in `docs/SYNC.md`.

## lil health

- **What it is:** Apple Health on the Mac. macOS has no Health app (as of macOS 27).
  - The iOS app reads Apple Health and uploads it to `api.lil.tech`.
  - The macOS app syncs it and renders it like iPad Health.
- **Why a server:** App Store guideline 5.1.3 forbids storing personal health data in iCloud, so the iPhone can't hand data to the Mac through CloudKit.
- **iOS app:** a minimal bridge: sign in, consent, grant Health access, sync status.
- **Data:** v1 syncs every readable HealthKit type, including workouts and routes, ECG, heartbeat series, audiograms, medications and State of Mind.
  - Clinical records (Health Records) are out of scope, because they need an entitlement that depends on App Review approval.
- **Statistics:**
  - **Cumulative types** (steps, energy, distance…): the iPhone computes 30-minute sums with HealthKit's own statistics queries, so de-duplication by source priority (e.g. iPhone and Watch steps) matches Health exactly.
    - 30-minute buckets keep days exact in half-hour time zones. Only offsets ending in :45 are approximate.
    - The Mac adds buckets up into days in its current time zone.
  - **Discrete types** (heart rate, weight…): the Mac computes averages, minimums and maximums from raw samples. Averages of bucket averages would be wrong, and HealthKit's statistics don't include sample counts to weight them.
  - Raw samples also back "Show All Data".
- **Multiple iPhones:** every signed-in iPhone uploads, relying on Health's iCloud sync to give them the same data.
  - Samples de-duplicate by HealthKit UUID.
  - Statistics are stored per iPhone, and the Mac reads one statistics source: the iPhone paired with an Apple Watch, otherwise the most recently active one. An iPhone that's behind on iCloud sync can't overwrite a complete one.
  - Not supported: Health iCloud sync turned off, or iPhones on different Apple IDs in one lil account. Signing in on a second iPhone shows a warning about this.
- **Privacy:**
  - Health data is readable by the server and encrypted at rest by Cloudflare. That keeps server-side features possible, such as an MCP server later.
  - It's processed only with explicit consent (GDPR special-category data), and never used for ads or sold.
  - Real health data never goes into staging, previews, tests, commits or tickets.
- **Availability:** permanently free, with no subscriptions, ads or paid tiers.
  - Signup is open, in every App Store region except mainland China (data-localization rules). The server also refuses new accounts from mainland China, since the Mac app is downloaded directly.
  - Rate limits and per-user storage quotas keep costs in check.

## lil messages

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

- What "lil" means as a product idea, and what v1 of lil messages includes.
- Whether App Review accepts a bridge-only iOS app (guideline 4.2). Revisit when lil health is ready to publish.

## Notes

- `chat.db` is in WAL mode, so we can read it live while Messages.app writes to it.
- Some message text lives only in `attributedBody`, an `NSAttributedString` archived in the legacy typedstream format, not in `text`. `AttributedBody.text(from:)` reads just the string payload in pure Swift, instead of using the deprecated, non-secure `NSUnarchiver`. It matched `NSUnarchiver` on all ~70k blobs in a real `chat.db` and runs about 20× faster.
- `attributedBody` is the more complete source of text. `text` sometimes omits leading content (e.g. mentions), and differs by U+FFFC attachment placeholders.
