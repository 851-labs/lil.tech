# Decisions

## Repo

- **Monorepo:** lil.tech holds all our apps and the API they share. Apps are written in Swift, the server in TypeScript. lil messages came first (now paused), then lil health, then lil mail, lil calendar, lil browser, and others.
- **Naming:** app names are lowercase everywhere users see them, even at the start of a sentence: "lil messages", "lil mail". Code identifiers keep Swift casing (`LilMessages`).
- **Open source:** Apache 2.0. Real user data (e.g. `chat.db`, Health data) is never committed. Test fixtures are synthetic.
- **Layout:**
  - `Lil.xcworkspace`
  - Thin app projects under `Apps/`: one project per app, with a target per platform (851-2684). `Apps/LilHealth/LilHealth.xcodeproj` has `LilHealth` (macOS) and `LilHealthiOS`, sharing project-level settings (version, team, bundle ID, Swift flags). Each target keeps its own entry point, signing, entitlements, `<Target>-Info.plist` and assets. Not one multiplatform target: the entry points and signing differ too much.
  - One SPM package with many small modules
  - TypeScript in one pnpm workspace at the repo root (851-2683): servers in `Services/` (the API), web projects in `Web/` (the website now, web apps later). The site moved out of `Services/`, where it only sat because the API's stack deploys it. Not a lowercase `apps/`, which would collide with `Apps/` on macOS's case-insensitive disks.
  - Code moves into a shared module once a second app needs it, not before (e.g. a ⌘K command palette)
- **Bundle IDs:** `tech.lil.messages`, `tech.lil.mail`, and so on. An app that ships on several platforms uses one App ID for all of them (e.g. `tech.lil.health` on iOS and macOS).
- **Formatting:** swift-format with 2-space indents for Swift, and Vite+'s formatter and linter (Oxfmt, Oxlint) for TypeScript, enforced by the pre-commit hook.
- **Branching:** trunk-based, with short-lived PRs into `main`.
- **Tickets:** every app stays in the Linear project lil.tech, told apart by labels (`lil health`, `api`, …).

## Platform and language

- **Platforms:** macOS 26 and later. No Perception needed.
  - lil health also ships on iOS, with a minimum of iOS 26. lil messages stays macOS-only.
  - Shared modules should avoid AppKit where it's cheap to do so.
- **Swift:** latest toolchain (Swift 6.4, Xcode 27), Swift 6 language mode with complete strict concurrency, on every target.
  - All upcoming Swift 7 features are on: `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`, `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`, `ImmutableWeakCaptures`.
  - Checks treat warnings as errors (`CI=1`, which the pre-commit hook sets), for our own targets only (warnings from third-party packages don't count). Warnings stay warnings in everyday builds.
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
- **Updates:** Sparkle, with EdDSA-signed updates. Each app has its own key, in Alexandru's login keychain (account `lil-<app>`) and backed up in 1Password. The public key is in the app's Info.plist (for lil health, the Mac target's `LilHealth-Info.plist`). lil messages' first key was lost without a backup and replaced in October 2026 (851-2685). Installed copies still update, through Sparkle's key rotation for Developer ID-signed apps, as long as the Developer ID certificate doesn't change in the same release.
- **Releases:** GitHub Releases host the DMGs. Each app's appcast is committed to the repo (`appcasts/<app>.xml`) and served from `raw.githubusercontent.com`, because GitHub's "latest release" URL is repo-wide.

### iOS apps

- **TestFlight and the App Store**, which HealthKit requires. Release builds are signed with Apple Distribution and uploaded to App Store Connect.

### Everywhere

- **CI:** for now, checks run locally, before every commit, in a lefthook pre-commit hook (`lefthook.yml`, `scripts/check`), only for the parts a commit touches. GitHub only deploys (`services.yml`: PR previews, then staging and prod on merge to `main`).
  - Why: GitHub's Swift workflow took 6–11 minutes, mostly a cold runner restoring caches, while the same checks take about 70 seconds on a warm Mac.
  - The Swift workflow (`swift.yml`, GitHub's `xcode-27` image with Xcode 27.0) is kept, but only runs by hand. Turning it back on means restoring its `pull_request` and `push` triggers.
  - The trade-off: nothing re-checks a commit made with the hook skipped, or merges that combine changes. Keep commits passing, and merge only branches that are up to date with `main`.
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
  - **Drizzle for the core D1 database** (851-2686), ahead of lil mail and lil calendar adding core tables. `drizzle-orm` and `drizzle-kit` are pinned to `1.0.0-rc.5-ab785fc`, the exact build Alchemy beta.83 is built against.
    - The schema is `src/core/Schema.ts`. drizzle-kit generates migrations from it into `migrations/core`, in its own folder format (`<timestamp>_<name>/migration.sql` plus a snapshot), which Alchemy's D1 resource applies on deploy.
    - Migrations are generated in the repo, never at deploy: `scripts/format` runs drizzle-kit, and `scripts/format --lint` fails if the schema changed without a migration (`scripts/migrations.ts`). Alchemy's `Drizzle.Schema` resource, which generates during deploy, isn't used.
    - What Drizzle can't express (the Apple token revocation trigger) is SQL appended by hand to a generated migration, after a `--> statement-breakpoint` (the only place Alchemy splits statements).
    - Alchemy picks one migration format per folder. Mixing our old numbered `.sql` files with Drizzle's folders would have hidden the old ones, which Alchemy then treats as rewritten history.
    - Repositories query `CoreDb` (`src/core/CoreDb.ts`): Drizzle over D1 in the Worker (`drizzle-orm/effect-d1`) and over Node SQLite in tests (`drizzle-orm/effect-sqlite-node`), one type for both. They keep failing with `SqlError` (`query()` unwraps Drizzle's error to the driver's), so callers didn't change. Every core repository is on Drizzle (851-2687, 851-2688), and the Worker no longer provides `SqlClient` for the core database. Queries the builder can't express (Consents' race-safe `INSERT … SELECT … WHERE NOT EXISTS`) use Drizzle's `sql` template over the schema's columns.
    - The per-user store stays on raw SQL: its bulk upserts are hand-tuned, and its migrations must stay additive, which drizzle-kit's table rebuilds don't respect.
  - **The October 2026 wipe** (851-2686): with no users, we started over instead of carrying the old migration history.
    - The core database's resource ID changed (`Core` → `Core2`), so Alchemy created a fresh database from the Drizzle baseline and deleted the old one.
    - The store's Durable Object ID changed (`UserStore` → `UserStore2`), so Alchemy deleted the old class and Cloudflare deleted every store of it. Under the same ID, a renamed class would have kept its data.
    - R2 buckets stayed. Objects of users the new database doesn't know, and snapshot parts uploaded before the cutover, were deleted by a one-off script.
    - Health batches still queued at cutover are dropped: ingestion skips users the core database doesn't know, so it can't create a store for nobody.
  - IDs are a type prefix plus a 26-character time-sortable code (e.g. `usr_01jb…`), with branded Effect Schema types. Times are Unix milliseconds.
  - Each user's own data (health now, mail and calendar later) lives in that user's SQLite-backed Durable Object.
  - A store migrates its own schema the first time it's used after a deploy, from migrations listed in code (`src/store/Migrations.ts`). Migrations are additive only, because a rolled-back Worker can meet a store that newer code already migrated. The migrator is ours, not Alchemy's `SqlMigrations`, so it runs in tests on `node:sqlite`.
  - Large blobs (ECG voltages, workout routes, sync snapshots) live in R2.
  - R2 blobs are immutable and addressed by content hash. They're only deleted with a grace period (or when an account is deleted), and snapshots can be rebuilt from the Durable Object.
    - Health blobs no record refers to (e.g. an ECG deleted in Health) are deleted by the user's store 35 days after they lost their last reference, longer than the 30 days of point-in-time recovery (`docs/SYNC.md`).
  - The exception is uploads waiting to be applied, such as health batch files. They're staging, not data: keyed by user and batch, deleted once applied, and expired by a 7-day lifecycle rule if anything leaves them behind.
  - **Deleting R2 objects** (851-2655, `deleteObjects`): 100 keys per call, 6 calls at once, not R2's limit of 1,000 per call. A call takes as long as its slowest keys, and R2 has slow spells (the same deletes took 10 times as long from one run to the next, and deletes just after many writes were slow too). On a personal stage, a store deleting 2,000 objects that had aged 15 minutes took 6.3–8.1 s with 1,000-key calls one at a time, and 1.7–1.9 s with 100-key calls six at once, alternating over three rounds. That's about 9 s for 10,000. More than 6 at once wasn't faster, since a Worker keeps at most 6 connections open. A 1,000-key call took up to 48 s in a slow spell, and prod's wipe of 2,644 snapshot parts took minutes per call. No call was throttled (10058) in these runs; a throttled call is tried again, and with smaller calls that's only 100 keys.
  - Not D1 for user data, because one D1 database has a hard 10 GB cap shared by everyone, and a Worker can't bind a new database per user at runtime.
- **Backups:** D1 and Durable Object point-in-time recovery (30 days). R2 has none, which is why blobs are immutable.
- **Storage quota:** each user's store may grow to 8 GB, below the 10 GB a Durable Object can hold. The size is SQLite's used pages (workerd's `databaseSize`), so deleted records make room once the change log is compacted. Health blobs in R2 count towards the same 8 GB.
  - At the quota, new batch and blob uploads fail with 507 `StorageFull`, before anything reaches R2. A batch or blob the store already knows still answers.
  - Batches accepted before the quota are still applied, because the iPhone never sends a batch again once it's accepted. The gap up to the cap absorbs them.
  - On the iPhone, a 507 ends the backfill run, since every other upload would be refused too.
    - The pending page is kept so it goes up once there's room, and types the run didn't reach are asked for again.
    - The sync status screen shows **Storage full** with Try Again.
    - While full, syncs for changes wait 6 hours between tries, and no background task is requested. Opening the app and Try Again always try.
    - The first upload that goes through clears the state.
  - At a 9.5 GB hard limit, writes of new records fail too, so the store never reaches the cap. Deletes still apply. A queued batch that meets the limit fails ("The storage quota is full; N lines were applied before it") rather than retrying.
  - **Largest users:** after applying each health batch, the queue consumer records the account's storage in D1 (`users.storage_bytes`, `storage_measured_at`): the store's size plus its health blobs'. Batches are where the store grows, and blobs are uploaded just before the batches that refer to them, so the figure lags uploads only briefly. Measurements that arrive out of order don't overwrite later ones, and recording is best-effort. To list the largest users, run `Services/api/scripts/largest-users.sql` in the D1 console for the stage's core database. It shows only IDs and sizes, and tests run that same file.
  - Every error a store returns is listed in `userStoreErrors`, so it crosses Durable Object RPC as itself. Test stores pass any other error as a plain object, as RPC would, so a missing entry fails the tests.
- **Health ingest throughput** (851-2647, measured on a personal stage with synthetic step samples, 20k-item batches):
  - A user's store (one Durable Object, one thread) is the ceiling for that user. Batches apply in store calls of up to 5,000 lines or 4 MB, the consumer reads the next chunk while one applies, and the queue applies at most 2 batches at once. This went from 1,926 to 5,280 items/s end to end.
  - The limit of 2 (raised to 4 below) is global, not per user: 3 overloaded the store, failing uploads with 503, and 1 left it idle between batches (2,657 items/s). Smaller calls (2,000) were slower (2,962 items/s) at the same upload latency.
  - Most of the store's CPU (about 150 of 200–220 µs per item) went to inserting HealthKit's random UUIDs into the `id` index; time-ordered IDs cost 59 µs. So samples are stored by type and start date, with no index on `id` alone, and deletes leave tombstones that the alarm sweeps (851-2651, `docs/SYNC.md`). With real random UUIDs that's about 80 µs per item and 6,594 items/s end to end. The store is then about half busy, but a limit of 3 was still slower (3,401 items/s, with uploads up to 3 s), so it stays 2.
  - **4 batches at once** (851-2675) since applying got cheaper: grouped upserts (851-2671) and a change log without row copies (851-2673, 851-2676). A consumer invocation then took about 1.5 s for 0.4 s of store time, so 2 left the store idle. On a personal stage (synthetic, 200,000 samples, 4 uploads in flight), 4 applied 3,417–4,686 items/s against 2's 2,544–3,293 with 2,500-record batches, and 4,624–6,538 against 4,242–5,366 with 5,000-line batches (4 MB calls). Upload latency was the same (about 0.5 s median), with no 503s or overloaded errors over two hours of runs. Calls hold at most 2 MB of line text (was 4 MB), so 4 consumers sharing an isolate keep the memory 2 had.
  - **4 batches at once per user** (851-2652), not globally. Each user's store takes at most 4 batches at once (`healthBatchesAtOnce`), holding each one's place in memory until it's applied or fails (or for 2 minutes, if it never says). A store that restarts starts with none. A batch whose turn hasn't come is sent back to the queue as a new message, delayed, so waiting holds no consumer and doesn't use up its 5 retries. Its `queued` timeout restarts each time.
    - **Order:** batches start in about the order they were received, so a later batch (say, a deletion) can't be applied before an earlier one it undoes. Only the 8 oldest waiting batches may take a free place. A waiting batch is one still `queued` that was received or turned away in the last minute, so a batch whose message was lost stops holding others back after a minute. A retry after a batch failed partway carries on, ahead of the line.
    - **Waits:** the 8 next in line ask again after a second. Others ask again after a quarter of a second for each batch ahead of them, up to 20 s, so a long backlog costs a few store calls a second. In load tests a batch was delivered about 4 times.
    - **Consumers:** the queue handles 16 messages at once across users (`healthBatchConsumers`), two users' batches plus those being turned away. With 8, two users got about 4,600 items/s each, because the turned-away messages queued behind the applying ones. Not more, because consumers can share an isolate and each applying batch holds up to two 2 MB chunks and their mutations.
    - **Measured** on a personal stage (synthetic, 120,000 samples a user, 5,000-line batches, 4 uploads in flight): one user applied 8,261–9,486 items/s (5,263–6,578 with the global limit), and two users at once 6,235–9,054 items/s each, with no failed uploads or invocations. A deploy that changes the consumer's settings paused delivery for about a minute.
  - **5,000-record batches from the iPhone** (851-2677): with the server the ceiling, smaller batches cost more than they save. With 4 consumers, 2,500-record batches applied at 3,417–4,686 items/s (4 MB calls, which they never reach) and 5,000-line ones at 5,872–7,851 (2 MB calls, so two per batch, the second read while the first applies). The test kept 4 uploads in flight; the iPhone keeps 2 (a 10,000-object page), but uploads a page in about one upload's time, faster than the server applies, so the queue stays full either way and the batch size sets the rate. A retried batch resends and re-applies up to 5,000 records.
  - Prod's one store (the developer's own data) is emptied by deleting the account before that deploy, rather than migrated in place, since copying millions of rows at the store's start could exceed a Durable Object's CPU limit.
- **Mac sync throughput** (851-2649): writing a change cost much more than the change itself. StructuredQueries built each row's upsert (`ON CONFLICT` and all) for 68 µs, against 3 µs through one prepared statement. So `healthSamples` and `healthStatistics`, the tables with millions of rows, upsert through a cached statement (`HealthDatabase.preparedEntity`), with GRDB as a direct dependency. A test checks their column lists against the tables. With 5,000-change pages and the next page downloading while one is written, a catch-up of 50,000 samples went from 14.2 s to 6.6 s (Release). Bootstraps download four snapshot parts at a time (each file once), hashing and writing them off the sync engine's actor, and parts whose URLs expire together share one refresh. What remains is decoding each page into OpenAPI's generic containers and re-decoding rows; going further would mean an endpoint that sends changes as NDJSON.
- **Billing and usage notifications:** Cloudflare emails alexandru@851.sh when the month's spend reaches $25 and again at $100. It also emails when Workers requests, Durable Objects requests, or D1 rows read or written pass what Workers Paid includes, and when R2 class A or B operations pass R2's free tier, meaning we've started paying for them.
  - Queues and CPU time have no usage alerts, so spend covers them.
  - The policies are account-wide, not per stage, so they live in `Services/api/scripts/notifications.ts` rather than the Alchemy stack. That also keeps the CI deploy token free of notification permissions.
  - To change them, edit the script, then run `node scripts/notifications.ts` from `Services/api` (add `--dry-run` to preview). Don't use `vp run`, whose tasks are cached and don't see your environment. It matches policies by name and leaves others alone. It needs `CLOUDFLARE_API_TOKEN` with Notifications: Edit, or an Alchemy OAuth login that was granted the notifications scopes, which "Basic Scopes" doesn't include.
- **Rate limits** (`src/RateLimits.ts`), counted with the Workers rate limiting binding:
  - Sign-ins: 60 a minute per IP address (`cf-connecting-ip`), shared by Apple, Google and dev sign-in. They're unauthenticated and create accounts, so the address is the only key there is.
  - Refreshes: 600 a minute per IP address, separately, so sign-in attempts can't block refreshes, and every device behind a carrier NAT can still refresh.
  - An IPv6 address counts by its /64, since one client usually has a whole /64.
  - Authenticated requests: 600 a minute per user, counted after the access token is verified, so a bad token costs nobody's budget. That includes the live socket. Signing out isn't counted, because a refused sign-out would leave the refresh token working.
  - Over a limit, the API answers 429 `TooManyRequests` with `retryAfterSeconds` (and `Retry-After` on routes outside the HttpApi). The apps wait it out. The Mac's sync waits at least `retryAfterSeconds` before trying again. The iPhone's backfill pauses (it isn't a failure) and keeps its page: syncs for changes wait until the time is up, while a run of everything (opening the app, Continue, a background task) waits it out, showing as running, and carries on, including when the 429 comes partway through. A rate-limited refresh keeps the session.
  - Counting is approximate and per Cloudflare location. It's also permissive: on a preview, a burst got a few hundred requests past a limit of 60 before 429s began. That's still enough to bound abuse. A Durable Object would count exactly, but would add a hop to every request.
  - If the binding fails, the request goes through. An outage of rate limiting shouldn't take the API down.
  - Each stage has its own namespace IDs (a hash of the stage name), since bindings that share an ID share counters across the account.
  - Snapshot part downloads aren't limited: their URLs are signed and short-lived.

## Accounts

- **Auth:** our own, written in Effect. Sign in with Apple and Sign in with Google.
  - The apps sign in natively. The server verifies the provider's ID token and issues its own session: short-lived access tokens and rotating refresh tokens.
  - **Sign in with Apple:** the app sends Apple the SHA-256 (hex) of a random nonce and sends us the nonce with Apple's identity token. The server checks Apple's signature (keys fetched through Cloudflare's cache), the issuer, the audience (`tech.lil.health` for the iPhone's native sheet, or the Mac's Services ID `tech.lil.health.web`, below), expiry, a 10-minute maximum age and the nonce. Apple only gives the name on the first sign-in, so the app sends it then.
    - **On the Mac, through Apple's web page** (851-2678): a Developer ID–distributed Mac app can't use the native sheet (Developer ID profiles can't carry the Sign in with Apple capability, 851-2538). The Mac opens `appleid.apple.com/auth/authorize` with the Services ID `tech.lil.health.web` (grouped under `tech.lil.health`, so the Apple user ID is the same) in a web authentication session. Apple posts the result to `POST /v1/auth/apple/web` (registered for `api.lil.tech` and `api.staging.lil.tech`), which redirects to `tech.lil.health://apple-signin` with the identity token, Apple's authorization code (for revoking, below), `state` and the first sign-in's name. It refuses posts from another web origin or over 16 KB with an `error` in the same redirect, and isn't rate limited (the sign-in that follows is). The app signs in through `POST /v1/auth/apple`, which accepts either audience. The iPhone keeps the native sheet. Previews can't be registered with Apple and keep the test-account sign-in.
  - **Sign in with Google:** the apps use Google's native sign-in with a nonce, like Apple (Google gets its SHA-256, we get the nonce), and send us the ID token. The server checks Google's signature, the issuer, the audience and authorized party (our OAuth client IDs, listed in `src/auth/Google.ts`), expiry, a 10-minute maximum age, the nonce and a verified email. Without client IDs listed, the endpoint answers 503.
    - **Google Cloud** (851-2538): the project "lil tech" (`lil-tech-851`, in the 851.sh organization, owned by alexandru@851.sh). Its consent screen is "lil health", external and in production, with only `openid`, `email` and `profile`, so it needs no Google review. Its home page is `lil.tech`, its privacy policy `lil.tech/privacy`, and `lil.tech` is verified in Search Console (a DNS TXT record on Cloudflare; don't remove it). One iOS-type client for `tech.lil.health` serves the iPhone and the Mac, which share that bundle ID. The support email is alexandru@851.sh for now: Google only accepts the owner's address or a Google Group they manage, so hello@851.sh would have to become a group.
  - Provider keys are fetched through Cloudflare's cache, and past it at most once a minute (for a new key ID). If they can't be fetched, sign-in answers 503 `SignInUnavailable`, so the app retries.
  - **Each provider ID token signs in once.** Used tokens are recorded (as hashes) until they expire, so a captured sign-in request can't be replayed.
  - **Access tokens:** 15-minute HS256 JWTs carrying the user, device and session. They're verified without a database read, so signing out takes up to 15 minutes to reach them. Each stage has its own signing key, generated and kept by Alchemy.
  - **Refresh tokens:** opaque and random, stored only as SHA-256 hashes. Each one works once: refreshing returns a new pair and revokes the old token. A refresh token expires 90 days after it was issued, so a device that opens the app at least every 90 days stays signed in.
  - **Reuse ends the session.** Presenting an already-used refresh token revokes every token descended from the same sign-in, since only a stolen copy (or a retried request whose response was lost) would do that. The app then signs in again. There's no grace period.
  - **No transactions:** D1 has none over HTTP, so a refresh stores the new token before conditionally revoking the old one. A refresh that fails partway leaves the old token working. Concurrent refreshes, or a refresh racing sign-out, end with the whole family revoked.
  - **Dev sign-in:** previews and personal stages have `POST /v1/auth/dev`, which signs in as a new synthetic user, or to a named one (`account`) that several devices share. That's how previews are checked end to end, since provider sign-in needs real accounts. Staging and prod never register the route. Simulator and Debug Mac builds pointed at a preview offer it on the sign-in screen (the account `e2e`), so the whole sync can be run with synthetic data.
  - Signing out deletes the device's session family. Refreshing deletes the family's expired tokens. Deleting a device or user deletes its sessions.
  - **In the apps** (`LilAuth`):
    - The session lives in the data protection Keychain, readable after first unlock, on this device only.
    - The `LilAPI` client adds the access token through transport middleware. It refreshes a token a minute before it expires, one refresh at a time. A 401 refreshes and retries the request once.
    - A refresh token the server rejects signs the app out. Other refresh failures (no network, 5xx) keep the session for the next try.
    - Expiry is tracked on the device's clock: the server's times, shifted by how far the device's clock was from the server's when the access token was issued (its `iat`). That way, a clock that's off doesn't make every token look expired.
    - Signing out forgets the session first, then tells the server with the access token it had.
    - The sign-in screen uses the stock Sign in with Apple button, with a Google button under it.
    - **Google without its SDK:** the apps open Google's sign-in page in `ASWebAuthenticationSession`, using the authorization code flow with PKCE. They redirect to the reversed client ID and redeem the code at Google's token endpoint for the ID token. iOS-type clients have no secret. Each app's client ID is `GIDClientID` in its Info.plist (`Apps/LilHealth/<Target>-Info.plist`). Until it's set, the Google button is hidden.
- **Identities and connections are separate:**
  - An identity is a way to sign in. Signing in with Google requests identity scopes only.
  - A connection is a data source the user grants access to, with its own scopes, credentials and sync state: Apple Health now, Gmail, IMAP and calendars later.
- **Account linking:** never automatic by email. A signed-in user links another sign-in method explicitly.
- **Deletion and export:** users can delete their account and export their data from inside the apps.
  - **`DELETE /v1/me`** marks the user's store deleted, then deletes their uploaded batch files and blobs, then the user row. Deleting the user cascades to identities, devices, sessions and connections. Every step is idempotent, so a failed deletion can be retried.
    - The store wipes itself and its snapshots from its alarm, logging each step and retrying a failed one a minute later. Wiping a multi-gigabyte store within the request outlasted the iPhone's 60-second timeout (851-2653), and the app then said it was offline. It now reports only real network loss as offline.
  - **Other devices sign out at once** (851-2666): once the account and its sessions are deleted, the store closes its live connections with `4001`, so a signed-in Mac refreshes, fails and signs out within seconds (`docs/SYNC.md`). Devices without a live connection (an iPhone) learn at their next request. Apps from before 851-2666 sign out when their token expires, as before.
  - **Stale tokens:** the wiped store stays marked deleted and refuses writes. User IDs are never reused, so an access token that outlives the account (up to 15 minutes) can't write data back, and batches still queued are dropped.
  - **On the iPhone:** Delete Account, with confirmation, then signs out and clears what's local. Health's own data stays.
  - **Revoking Sign in with Apple** (851-2612), as Apple requires of apps with account deletion:
    - The apps send Apple's authorization code with the identity token. After signing in, the server redeems it at `appleid.apple.com/auth/token` (for the client ID the identity token was issued to: the App ID or the Services ID) and keeps the refresh token with the identity, encrypted (AES-GCM, with `LIL_TOKEN_KEY`, a random key per stage kept in Alchemy's state). It only keeps a token whose `sub` matches the signed-in identity. A failed redemption never fails the sign-in. That account just can't have its token revoked, until it signs in again. Each sign-in that sends a code replaces the stored token, whichever app it came from. One token per identity is enough while the Services ID stays grouped under the App ID: they're one authorization, so revoking either token ends it, and Apple emails the person "lil health has revoked your Sign in with Apple" (851-2681). If the latest sign-in's redemption failed, the stored token may belong to an authorization that already ended, and the current one isn't revoked.
    - The Mac's web sign-in codes are redeemed with their `redirect_uri` (the API's own `/v1/auth/apple/web`), which Apple requires when the authorization request had one.
    - Deleting an identity (also through its user's cascade) queues its token in `apple_token_revocations`, from a trigger, so the queueing is atomic with the deletion, and a token saved by a concurrent sign-in can't slip through. `DELETE /v1/me` then revokes them at `/auth/revoke`. A failure doesn't fail the deletion. The daily cron tries again an hour later, doubling up to 23 hours (so the next daily run finds it due), for 14 attempts, and drops tokens Apple calls `invalid_grant`. Apple's revoke endpoint answers 200 even for unknown tokens and wrong client secrets, so only a real sign-in proves the setup.
    - Both endpoints need a client secret: an ES256 JWT, valid for 5 minutes, signed with the team's Sign in with Apple key (`J59CSK4YXA`, in 1Password as "lil health – Sign in with Apple key (J59CSK4YXA)"). The deploy reads it from `LIL_APPLE_SIGN_IN_KEY` (the `.p8` PEM; a repo secret in CI) and binds it as a Worker secret. Staging and prod refuse to deploy without it. Elsewhere it's optional, and without it the server skips both calls.

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
  - Workouts are `health_workout` records: the overall activity type, times and duration, plus their activities (multisport legs), events (pauses, laps, segments) and per-type statistics as JSON, in the catalog's units. The iPhone reads them through the same anchored backfill as samples. Routes come separately (851-2566).
  - State of Mind logs (`health_state_of_mind`) and GAD-7/PHQ-9 assessments (`health_scored_assessment`) keep HealthKit's raw values for kinds, labels, associations, risks and answers, so the Mac can name them in the user's language.
  - Audiograms (`health_audiogram`) keep each tested frequency with its per-ear tests (sensitivity and clamping range in dBHL, conduction type, masking), as HealthKit's iOS 18.1 model has them.
  - ECGs (`health_electrocardiogram`) keep their classification, symptoms status, average heart rate and sampling frequency in the row. The voltages (lead I) are a blob of little-endian 32-bit floats in microvolts, one per measurement, about 60 KB for a 30-second recording. The iPhone reads them 50 ECGs to a page, so a page's blobs stay small in memory. The symptoms themselves are category samples, synced like any other.
  - Workout routes (`health_workout_route`) keep their locations in a blob, 44 bytes each (time, latitude and longitude as 64-bit floats; altitude, accuracies, speed and course as 32-bit), about 160 KB for an hour at 1 Hz. The iPhone reads them 10 to a page. HealthKit only queries routes by workout, so the iPhone finds each route's workout among the workouts its time overlaps and stores it (`workout`, or `null` if none links it). A later blob format would add a `locationsFormat` field; rows without one are this format. They're precise location data, which the privacy policy says.
  - Heartbeat series (`health_heartbeat_series`) keep each beat's time (seconds since the start) and the indices of beats preceded by a gap, as JSON in the row. They're about a minute and a hundred beats each (~2 KB), so a blob per reading would cost an R2 object, a quota row and a download, thousands of times a year, for little. The iPhone reads them 200 to a page, since each needs its own query.
  - Characteristics (date of birth, sex, blood type…) and Activity summaries have no anchors, so every run of everything reads them. Characteristics go up when their content changes (a hash in the backfill's state). Activity summaries go up all at once the first time, then the last 30 days', whose numbers and goals can still change (e.g. when a Watch that was away syncs). A characteristic that stops being readable is deleted. A locked phone pauses the run rather than looking like removed characteristics.
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
    - An iPhone that signs out has its device row deleted, and its device-scoped rows are deleted from the store a chunk at a time (`docs/SYNC.md`). So a signed-out Watch-paired iPhone can't stay the source. One that stops without signing out (app deleted, tokens expired) is retired by a daily job once it has no live session and hasn't been seen for a day. Until then, the Mac's 14-day rule skips it.
  - Not supported: Health iCloud sync turned off, or iPhones on different Apple IDs in one lil account. Signing in on a second iPhone shows a warning about this: after sign-in, the app checks `GET /v1/me`'s `devices` once per account for another `health-ios` install.
- **Privacy:**
  - Health data is readable by the server and encrypted at rest by Cloudflare. That keeps server-side features possible, such as an MCP server later.
  - It's processed only with explicit consent (GDPR special-category data), and never used for ads or sold.
    - **Consent** is to a privacy policy version, its effective date (`healthConsentPolicyVersion` in `src/core/Consents.ts`). The server records each consent and withdrawal in D1's `consents` table with its time, as proof of consent, and deletes them with the account.
    - `GET /v1/me/consents/health` returns the required version and the consent in force. `POST` with the version the app showed records consent; an older version gets 409 `ConsentOutdated`. `DELETE` withdraws it.
    - New batch uploads without a current consent fail with 403 `ConsentRequired`, before anything reaches R2. A batch the store already knows still answers with its status, and batches accepted before a withdrawal are still applied. Data already uploaded stays until the account is deleted.
    - Bumping the version, for a change in how Health data is used, refuses uploads until each user consents again.
    - **On the iPhone,** the consent screen comes after sign-in and before Health access: what's uploaded, where and why, a privacy policy link, and Agree or Not Now. Nothing is pre-checked. `HealthConsentClient.policyVersion` is the version the screen describes, so bump it with the screen.
      - The iPhone remembers the version it consented to (`healthConsentPolicyVersion` in app storage). Nothing uploads without it, including HealthKit's background wakes and background tasks. Each launch asks the server before uploading, which catches consent withdrawn or given on another iPhone (offline, the iPhone's answer stands). An upload refused with `ConsentRequired` clears it too, in the background as well. An answer that was out while consent was given or withdrawn here is dropped as stale.
      - The screen comes up on its own once per sign-in. After Not Now or a withdrawal, the home screen says nothing is uploading and offers it again.
      - Withdraw Consent in the account section clears the iPhone's consent and pauses uploads at once, tells the server, then offers to delete the account. If the server can't be told, consent stands again and uploading stays paused until the next change or launch.
  - Real health data never goes into staging, previews, tests, commits or tickets.
  - **Privacy policy:** at [lil.tech/privacy](https://lil.tech/privacy), under Alexandru Ţurcanu's name, since the apps are published from a personal App Store Connect account. Alexandru is the data controller. The contact is hello@851.sh. The iPhone app links it from sign-in and the account screen. Update its effective date and tell users in the app when a change affects how Health data is used.
- **Summary pins (Mac):** local to each Mac for now, in the app's user defaults, and cleared when the account signs out. Syncing them between Macs (a `health_pin` entity with a mutation endpoint) is 851-2641.
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
