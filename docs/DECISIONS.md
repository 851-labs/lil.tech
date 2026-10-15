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
  - A store migrates its own schema the first time it's used after a deploy, from migrations listed in code (`src/store/Migrations.ts`). Migrations are additive only, because a rolled-back Worker can meet a store that newer code already migrated. The migrator is ours, not Alchemy's `SqlMigrations`, so it runs in tests on `node:sqlite`.
  - Large blobs (ECG voltages, workout routes, sync snapshots) live in R2.
  - R2 blobs are immutable and addressed by content hash. They're only deleted with a grace period (or when an account is deleted), and snapshots can be rebuilt from the Durable Object.
  - The exception is uploads waiting to be applied, such as health batch files. They're staging, not data: keyed by user and batch, deleted once applied, and expired by a 7-day lifecycle rule if anything leaves them behind.
  - Not D1 for user data, because one D1 database has a hard 10 GB cap shared by everyone, and a Worker can't bind a new database per user at runtime.
- **Backups:** D1 and Durable Object point-in-time recovery (30 days). R2 has none, which is why blobs are immutable.
- **Storage quota:** each user's store may grow to 8 GB, below the 10 GB a Durable Object can hold. The size is SQLite's used pages (workerd's `databaseSize`), so deleted records make room once the change log is compacted.
  - At the quota, new batch uploads fail with 507 `StorageFull`, before anything reaches R2. A batch the store already knows still answers with its status.
  - Batches accepted before the quota are still applied, because the iPhone never sends a batch again once it's accepted. The gap up to the cap absorbs them.
  - On the iPhone, a 507 ends the backfill run, since every other upload would be refused too. The pending page is kept so it goes up once there's room, and the sync status screen shows **Storage full** with Try Again.
  - At a 9.5 GB hard limit, writes of new records fail too, so the store never reaches the cap. Deletes still apply. A queued batch that meets the limit fails ("The storage quota is full; N lines were applied before it") rather than retrying.
  - **Largest users:** after applying each health batch, the queue consumer records the store's size in D1 (`users.storage_bytes`, `storage_measured_at`). That's where the store grows, so the figure doesn't lag uploads. Measurements that arrive out of order don't overwrite later ones, and recording is best-effort. To list the largest users, run `Services/api/scripts/largest-users.sql` in the D1 console for the stage's core database. It shows only IDs and sizes, and tests run that same file.
  - Every error a store returns is listed in `userStoreErrors`, so it crosses Durable Object RPC as itself. Test stores pass any other error as a plain object, as RPC would, so a missing entry fails the tests.
- **Billing and usage notifications:** Cloudflare emails alexandru@851.sh when the month's spend reaches $25 and again at $100. It also emails when Workers requests, Durable Objects requests, or D1 rows read or written pass what Workers Paid includes, and when R2 class A or B operations pass R2's free tier, meaning we've started paying for them.
  - Queues and CPU time have no usage alerts, so spend covers them.
  - The policies are account-wide, not per stage, so they live in `Services/api/scripts/notifications.ts` rather than the Alchemy stack. That also keeps the CI deploy token free of notification permissions.
  - To change them, edit the script, then run `node scripts/notifications.ts` from `Services/api` (add `--dry-run` to preview). Don't use `vp run`, whose tasks are cached and don't see your environment. It matches policies by name and leaves others alone. It needs `CLOUDFLARE_API_TOKEN` with Notifications: Edit, or an Alchemy OAuth login that was granted the notifications scopes, which "Basic Scopes" doesn't include.
- **Rate limits** (`src/RateLimits.ts`), counted with the Workers rate limiting binding:
  - Sign-ins: 60 a minute per IP address (`cf-connecting-ip`), shared by Apple, Google and dev sign-in. They're unauthenticated and create accounts, so the address is the only key there is.
  - Refreshes: 600 a minute per IP address, separately, so sign-in attempts can't block refreshes, and every device behind a carrier NAT can still refresh.
  - An IPv6 address counts by its /64, since one client usually has a whole /64.
  - Authenticated requests: 600 a minute per user, counted after the access token is verified, so a bad token costs nobody's budget. That includes the live socket. Signing out isn't counted, because a refused sign-out would leave the refresh token working.
  - Over a limit, the API answers 429 `TooManyRequests` with `retryAfterSeconds` (and `Retry-After` on routes outside the HttpApi). The apps treat it like a 503: try again later, and keep the session.
  - Counting is approximate and per Cloudflare location. It's also permissive: on a preview, a burst got a few hundred requests past a limit of 60 before 429s began. That's still enough to bound abuse. A Durable Object would count exactly, but would add a hop to every request.
  - If the binding fails, the request goes through. An outage of rate limiting shouldn't take the API down.
  - Each stage has its own namespace IDs (a hash of the stage name), since bindings that share an ID share counters across the account.
  - Snapshot part downloads aren't limited: their URLs are signed and short-lived.

## Accounts

- **Auth:** our own, written in Effect. Sign in with Apple and Sign in with Google.
  - The apps sign in natively. The server verifies the provider's ID token and issues its own session: short-lived access tokens and rotating refresh tokens.
  - **Sign in with Apple:** the app sends Apple the SHA-256 (hex) of a random nonce and sends us the nonce with Apple's identity token. The server checks Apple's signature (keys fetched through Cloudflare's cache), the issuer, the audience (`tech.lil.health`, shared by the iOS and Mac apps), expiry, a 10-minute maximum age and the nonce. Apple only gives the name on the first sign-in, so the app sends it then.
  - **Sign in with Google:** the apps use Google's native sign-in with a nonce, like Apple (Google gets its SHA-256, we get the nonce), and send us the ID token. The server checks Google's signature, the issuer, the audience and authorized party (our OAuth client IDs, listed in `src/auth/Google.ts` once 851-2538 registers them), expiry, a 10-minute maximum age, the nonce and a verified email. Until the client IDs are listed, the endpoint answers 503.
  - Provider keys are fetched through Cloudflare's cache, and past it at most once a minute (for a new key ID). If they can't be fetched, sign-in answers 503 `SignInUnavailable`, so the app retries.
  - **Each provider ID token signs in once.** Used tokens are recorded (as hashes) until they expire, so a captured sign-in request can't be replayed.
  - **Access tokens:** 15-minute HS256 JWTs carrying the user, device and session. They're verified without a database read, so signing out takes up to 15 minutes to reach them. Each stage has its own signing key, generated and kept by Alchemy.
  - **Refresh tokens:** opaque and random, stored only as SHA-256 hashes. Each one works once: refreshing returns a new pair and revokes the old token. A refresh token expires 90 days after it was issued, so a device that opens the app at least every 90 days stays signed in.
  - **Reuse ends the session.** Presenting an already-used refresh token revokes every token descended from the same sign-in, since only a stolen copy (or a retried request whose response was lost) would do that. The app then signs in again. There's no grace period.
  - **No transactions:** D1 has none over HTTP, so a refresh stores the new token before conditionally revoking the old one. A refresh that fails partway leaves the old token working. Concurrent refreshes, or a refresh racing sign-out, end with the whole family revoked.
  - **Dev sign-in:** previews and personal stages have `POST /v1/auth/dev`, which signs in as a new synthetic user. That's how previews are checked end to end, since provider sign-in needs real accounts. Staging and prod never register the route.
  - Signing out deletes the device's session family. Refreshing deletes the family's expired tokens. Deleting a device or user deletes its sessions.
  - **In the apps** (`LilAuth`):
    - The session lives in the data protection Keychain, readable after first unlock, on this device only.
    - The `LilAPI` client adds the access token through transport middleware. It refreshes a token a minute before it expires, one refresh at a time. A 401 refreshes and retries the request once.
    - A refresh token the server rejects signs the app out. Other refresh failures (no network, 5xx) keep the session for the next try.
    - Expiry is tracked on the device's clock: the server's times, shifted by how far the device's clock was from the server's when the access token was issued (its `iat`). That way, a clock that's off doesn't make every token look expired.
    - Signing out forgets the session first, then tells the server with the access token it had.
    - The sign-in screen uses the stock Sign in with Apple button, with a Google button under it.
    - **Google without its SDK:** the apps open Google's sign-in page in `ASWebAuthenticationSession`, using the authorization code flow with PKCE. They redirect to the reversed client ID and redeem the code at Google's token endpoint for the ID token. iOS-type clients have no secret. Each app's client ID is `GIDClientID` in its Info.plist. Until it's set, the Google button is hidden.
- **Identities and connections are separate:**
  - An identity is a way to sign in. Signing in with Google requests identity scopes only.
  - A connection is a data source the user grants access to, with its own scopes, credentials and sync state: Apple Health now, Gmail, IMAP and calendars later.
- **Account linking:** never automatic by email. A signed-in user links another sign-in method explicitly.
- **Deletion and export:** users can delete their account and export their data from inside the apps.
  - **`DELETE /v1/me`** wipes the user's store and its snapshots, then their uploaded batch files, then the user row. Deleting the user cascades to identities, devices, sessions and connections. Every step is idempotent, so a failed deletion can be retried.
  - **Stale tokens:** the wiped store stays marked deleted and refuses writes. User IDs are never reused, so an access token that outlives the account (up to 15 minutes) can't write data back, and batches still queued are dropped.
  - **On the iPhone:** Delete Account, with confirmation, then signs out and clears what's local. Health's own data stays.
  - Revoking the Sign in with Apple token is 851-2612.

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
  - **On the Mac** (`HealthDatabase`):
    - Cumulative totals come from the statistics source's 30-minute buckets, placed by their start in the Mac's time zone.
    - Discrete averages follow each type's aggregation style:
      - **Arithmetic:** a plain average.
      - **Time-weighted:** each sample counts until its source's next sample, up to an hour, and a source's last one for its own duration. Sources are weighted separately, so a second device's readings don't cut the first's short.
      - **Sound levels:** an equivalent continuous level.
    - The statistics source is the Watch-paired iPhone among those that reported in the last 14 days, then the most recent of those. If none reported recently, it's the most recent of all. Ties go to the higher device ID.
- **Multiple iPhones:** every signed-in iPhone uploads, relying on Health's iCloud sync to give them the same data.
  - Samples de-duplicate by HealthKit UUID.
  - Statistics are stored per iPhone, and the Mac reads one statistics source: the iPhone paired with an Apple Watch, otherwise the most recently active one. An iPhone that's behind on iCloud sync can't overwrite a complete one.
    - Each iPhone's statistics are `health_statistic` rows, keyed by device, type and bucket. Its `health_statistics_device` row records whether it's paired with a Watch and when it last reported, and the Mac picks the source from those rows.
    - Both entities are device-scoped (`docs/SYNC.md`): the server stamps rows with the uploading device.
  - Not supported: Health iCloud sync turned off, or iPhones on different Apple IDs in one lil account. Signing in on a second iPhone shows a warning about this.
- **Privacy:**
  - Health data is readable by the server and encrypted at rest by Cloudflare. That keeps server-side features possible, such as an MCP server later.
  - It's processed only with explicit consent (GDPR special-category data), and never used for ads or sold.
  - Real health data never goes into staging, previews, tests, commits or tickets.
- **Availability:** permanently free, with no subscriptions, ads or paid tiers.
  - Signup is open, in every App Store region except mainland China (data-localization rules). The server also refuses new accounts from mainland China, since the Mac app is downloaded directly.
    - The server goes by the country Cloudflare gives the Worker (`request.cf.country`, which unlike the `cf-ipcountry` header doesn't depend on a zone setting). `CN` can't create an account (451 `SignUpUnavailableInRegion`), but an existing account still signs in. Hong Kong, Macau and Taiwan have their own codes and aren't affected. A VPN gets around it. That's accepted, since the point is not to offer the service there.
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
