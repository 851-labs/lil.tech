# Decisions

Every architecture and product decision made so far. This file holds the decisions that apply everywhere; each area has its own file, under `docs/decisions/` (851-2791). Read this one, and the areas a change touches.

## Areas

- [Distribution and CI](decisions/distribution.md): How the apps are signed, released and updated, and how checks run.
- [Server](decisions/server.md): The API: hosting, storage, limits and throughput.
- [Accounts](decisions/accounts.md): Sign-in, identities, linking, deletion and export.
- [Sync](decisions/sync.md): How apps sync with the server. The protocol itself is specified in [`docs/sync/protocol.md`](sync/protocol.md).
- [lil health](decisions/health.md): Apple Health on the Mac: data, statistics, privacy and the apps.
- [lil messages](decisions/messages.md): The iMessage client (paused).
- [Pixelbook](decisions/pixelbook.md): Snapshots of every state catalog, published and browsable.

## Repo

- **Monorepo:** lil.tech holds all our apps and the API they share. Apps are written in Swift, the server in TypeScript. lil messages came first (now paused), then lil health, then lil mail, lil calendar, lil browser, and others.
- **Naming:** app names are lowercase everywhere users see them, even at the start of a sentence: "lil messages", "lil mail". Code identifiers keep Swift casing (`LilMessages`).
- **Open source:** Apache 2.0. Real user data (e.g. `chat.db`, Health data) is never committed. Test fixtures are synthetic.
- **Layout:**
  - `Lil.xcworkspace`
  - Thin app projects under `Apps/`: one project per app, with a target per platform (851-2684). `Apps/LilHealth/LilHealth.xcodeproj` has `LilHealth` (macOS) and `LilHealthiOS`, sharing project-level settings (version, team, bundle ID, Swift flags). Each target keeps its own entry point, signing, entitlements, `<Target>-Info.plist` and assets. Not one multiplatform target: the entry points and signing differ too much.
  - One SPM package with many small modules, laid out as in Swift package below.
  - TypeScript in one pnpm workspace at the repo root (851-2683): servers in `Services/` (the API), web projects in `Web/` (the website now, web apps later). The site moved out of `Services/`, where it only sat because the API's stack deploys it. Not a lowercase `apps/`, which would collide with `Apps/` on macOS's case-insensitive disks.
  - Code moves into a shared module once a second app needs it, not before (e.g. a ⌘K command palette)
- **Bundle IDs:** `tech.lil.messages`, `tech.lil.mail`, and so on. An app that ships on several platforms uses one App ID for all of them (e.g. `tech.lil.health` on iOS and macOS).
- **Formatting:** swift-format with 2-space indents for Swift, and Vite+'s formatter and linter (Oxfmt, Oxlint) for TypeScript, enforced by the pre-commit hook.
- **Branching:** trunk-based, with short-lived PRs into `main`.
- **Development doesn't need Xcode** (851-2948, finished in 851-2970, 2026-10-22): agents and CI build, test, run and check UI from the command line, so any number of them can work at once on one Mac, with no shared Xcode to queue for. UI states are state catalogs in snapshot tests (AGENTS.md › UI states), not `#Preview`s, which were all deleted, with the helpers only they used (`previewFrame`, the dependencies' `previewValue`s); Xcode's `RenderPreview` checks and its MCP server (`.mcp.json`) went with them. Apps are built and run with `xcodebuild`, `open` and `simctl`, and inspected with `log`, `lldb` and `xctrace` (AGENTS.md › Without Xcode). Liquid Glass on the Mac only draws on screen, so it's checked by running the app. Xcode still opens the workspace, for the view and memory graph debuggers and Instruments' UI, which are rarely needed. A new screen gets a catalog, never a `#Preview`, which `scripts/format --lint` refuses.
- **Tickets:** every app stays in the Linear project lil.tech, told apart by labels (`lil health`, `api`, …).

## Swift package

- **One package,** `LilPackage`, for every app (decided again in 851-2791). Modules already keep apps apart (a module imports only the targets it declares), SwiftPM and Xcode build per module, and one `Package.resolved` keeps every app on the same versions, which the snapshot tests' images and macro trust rely on. Revisit once lil mail, calendar or browser land, if indexing or resolving slows down, or an app needs its own versions; product folders inside the package would come first.
- **Product folders** (851-3065): modules sit in a folder per product, `Sources/Health/…`, `Sources/Messages/…` and `Sources/Lil/…` (the shared `Lil<Thing>` modules and `lil`), and their tests likewise under `Tests/` (`LilTestSupport` and `lil-example` in `Tests/Lil`), each target's `path:` set in `Package.swift`, rather than 26 modules and 27 test targets side by side. The folder is the module name's product (`<Product><Thing>`, below), so module names, and imports, didn't change. A new product (lil mail) gets a folder of its own.
- **Module names** (851-2791) say whose a module is:
  - `Lil<Thing>`: shared by apps (`LilAPI`, `LilAuth`, `LilSync`, `LilUI`, `LilUpdates`). Code moves into one once a second app needs it, not before.
  - `<Product><Thing>`: one product's, where the product is the app's name without "lil" (`HealthDatabase`, `HealthUI`, `HealthUpload`, `MessagesDatabase`).
  - `<Product><Platform>App`: an app's shell for one platform target: its root feature, navigation and settings (`HealthMacApp`, `HealthPhoneApp`, `MessagesMacApp`). The Xcode targets stay thin entry points.
  - Screens that aren't the shell go in modules of their own when they're many (`HealthPages`). No `Feature` suffix: nearly every module has TCA features.
- **Renames and splits** this called for, each a mechanical PR: 851-2792 the splits, 851-2793 the renames. Types inside the renamed modules kept their names (`ConversationListFeature`, `MessageThreadFeature`, the `ContactNames` client).

  | Before | After |
  |---|---|
  | `HealthMacApp`'s data pages (Audiograms, Electrocardiograms, Heartbeat Series, Cycle Tracking, Sleep, Workouts, Mental Wellbeing, Vision Prescriptions, Medications), with All Data, a sample and Data Sources | `HealthPages`, on `HealthDatabase` and `HealthUI` (done in 851-2792) |
  | `HealthMacApp`'s preview support: `PreviewFrame` | `HealthPages`, with what else the Mac's pages and shell share (851-2792); deleted with the last previews (851-2970) |
  | `HealthMacApp`'s `PreviewDatabase` | `HealthDatabase`, next to the preview data it prepares (851-2792) |
  | `AppUpdates` | `LilUpdates` |
  | `GzipFiles` | `LilGzip` |
  | `MessagesApp` | `MessagesMacApp` |
  | `ConversationListFeature` | `MessagesConversationList` |
  | `MessageThreadFeature` | `MessagesThread` |
  | `OnboardingFeature` | `MessagesOnboarding` |
  | `MessageSending` | `MessagesSending` |
  | `ContactNames` | `MessagesContacts` |

  `HealthCatalog`, `HealthKitAccess`, `LilAPIGenerated` and `LilTestSupport` keep their names. Renaming a module with previews changed its snapshots' IDs then (`<Module>_<File>_<State>`), so Pixelbook's comparisons across that commit show them as removed and added, once, and so did moving previews to another module (851-2792's pages). State catalogs' IDs (`<screen>.<state>`) don't name the module.

  How 851-2792 drew the line: `HealthMacApp` keeps the shell (the app and sidebar, Summary, Browse's category and metric screens, settings and sync) and imports `HealthPages`, which never imports it. The pages a metric opens are public views; the rest of `HealthPages` stays internal. All Data, a sample and Data Sources went with the pages rather than staying in Browse, because Sleep opens them too. What both modules use became public in `HealthPages` (`Shared/`), which the shell already imports: `MetricFormat`, `Lazy`, `calendarDayChanges`, `previewFrame` (deleted in 851-2970) and the page colors. They're the Mac's only, so not in `HealthUI`, which the iPhone app builds too. `MainQueueScheduler` (a GRDB observation scheduler) and `preparePreviewDatabase` (since removed) to `HealthDatabase`, which keeps `HealthUI` free of the database the iPhone app doesn't use. Two previews of the shell's metric screen that sat with the pages (heart rate's overlays, sound levels) moved to `MetricDetailViewPreviews.swift` (since replaced by Metric Detail's state catalog, 851-2949).
- **Folders:** a module past about 15 files gets folders by feature, at most two levels deep (`HealthPages/Sleep/`, `HealthMacApp/Browse/`), with each view next to its feature. A file's name stays unique in its module, folders or not. Tests mirror their module's folders.
  - Modules with folders: `HealthMacApp` and `HealthPages` (851-2792); `HealthDatabase` (`Database/`, `Queries/` for what the shell asks, `PageQueries/` for the data pages', `Previews/`; `HealthDatabaseTests.swift`, which tests every folder, stays at its tests' top level), `HealthUpload` (`Backfill/`, `Encoders/`, `Readers/`, `Upload/`), `HealthPhoneApp` by screen (`App/`, `Consent/`, `HealthAccess/`, `SyncStatus/`, `Settings/`, `Background/`) and `LilAuth` (`SignIn/`, `Providers/`, `Session/`, `SignInMethods/`, `Account/`, next to `Resources/`) in 851-2793. Size alone doesn't decide: `HealthPhoneApp`, at 15 files, got folders because it splits cleanly into screens, each a feature and its view, while `MessagesDatabase`, also at 15, stays flat because it's one layer (records and the requests on them) with no features to group.
  - A test file goes in the folder of the code it mostly tests, even when it touches other folders' types (`HealthEncoderTests` checks `HealthBatchWriter`'s provenance entities from `Encoders/`).
  - Graph files name a catalog by module and file only (`Module/<Screen>Catalog.swift`), and snapshot IDs by screen and state, so moving it between folders changes neither.

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
  - The exception is sign-in buttons, which follow their brands: Apple's in its colors, and Google's as its branding guidelines draw it, with its G, Google Sans (bundled in `LilAuth`, a Latin subset under the SIL Open Font License) and its colors (851-2601).
  - lil health follows iPad Health, its reference, in its category colors and icons. On the Mac, though, pages are grouped `Form`s on the form's native background, with system sections, not iPad Health's cards (851-2989, 851-2997). Lists too long for a `Form` draw its look lazily (`LazyGroupedList`, built from plain `Section`s as a `List` is), as the record lists do (851-3032, 851-3056). `docs/decisions/health.md` has each page.
- **Loading spinners wait before showing** (851-3086, asked for by Alexandru, as Apple's apps do): a spinner for a load shows only once the load has run 200 ms, fading in, then stays at least 400 ms, so loads that finish sooner (most page opens and period changes) never flash one, and one that shows doesn't blink off (`DelayedProgressTiming.standard`, in `LilUI`, the shared module for SwiftUI views every app uses). Its time comes from `@Dependency(\.continuousClock)`, so tests drive it with `ManualClock`, and state catalogs set `delayedProgressTiming` to `.immediate`, so their loading states still show it (tests default to `.immediate` too, so a view in a test never sleeps on the unimplemented test clock). It's always laid out, a hidden spinner keeping its space until it shows, so nothing moves, and nothing turns out of sight.
  - **Beside or over content it doesn't replace,** while something updates: `DelayedProgressView(isLoading:)`. A page's spinner while the next period loads (`updatingIndicator`, `UpdatingSlot`), the row that loads a list's next page (`LazyGroupedList`'s `isLoadingMore`).
  - **A placeholder whose place the content takes** (a page, a chart, a map, the session check before a window's content): the loading state draws only its space, and `.delayedProgress(isLoading:)` on the view puts the spinner over it. Content that arrives while the spinner is in its minimum time stays hidden until that ends, then fades in as the spinner fades out.
  - **A row placeholder in a list or form,** which the loaded rows replace (a section's rows, a sheet's log): `DelayedProgressView()`. It only waits out the delay: its rows take its place as soon as they've loaded, since there's no one place to keep it.
  - **Feedback for a press shows at once:** a spinner in place of the button just pressed (Revoke…, Unlink, Turn Off, Show More in the remote access logs, the iPhone's Agree and Continue, signing in or linking an account, Preparing your export…) is a plain `ProgressView`. It's how the press shows it was taken, and the button is gone, so waiting would look like nothing happened.
  - **Progress isn't loading:** determinate progress (exports, upload and sync counts) and sync's status (the Mac's sidebar footer, which has its own delay, and the iPhone's upload bar) stay as they are.
- **Copy says only what people need** (851-3104, asked for by Alexandru, after a pass on lil health's Settings): what someone needs to decide or act, in plain words, as Apple writes its own Settings. No implementation details, limits or rare edge cases (an export a day, an account linked elsewhere): the error at that moment says so. Most rows need no footer, and one that does gets a short sentence. Confirmations are a short title, at most one short line on the consequence that matters, and a clear button. Disclosures people must be told stay, shortened: that agents usually send what they read to their AI provider, that Turn Off Agent Access stops every connected agent, that a revoked agent loses access. Settings names the privacy policy quotes keep their words until the policy changes with them, as “Allow command-line and agent access” did until 851-3114 renamed it “Allow access on this Mac”, with the policy.
- **UI:** SwiftUI for the app shell and all navigation (split view, sheets, settings, toolbar, windows).
  - AppKit only for leaf views where performance or control matters, e.g. the message list (`NSTableView`/`NSCollectionView`) and the composer (`NSTextView`).
  - Wrap AppKit views in `NSViewRepresentable` and pass the store in. AppKit code uses only `observe { }` and `store.send`, never navigation.

## Open questions

- What "lil" means as a product idea, and what v1 of lil messages includes.
- Whether App Review accepts a bridge-only iOS app (guideline 4.2). Revisit when lil health is ready to publish.
