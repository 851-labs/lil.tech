# AGENTS.md

Read `docs/DECISIONS.md` before starting work. It records the architecture and product decisions that apply everywhere, and links each area's own file under `docs/decisions/` (Distribution and CI, Server, Accounts, Sync, lil health, lil messages, Pixelbook). Read the areas your change touches too.

## Workflow

- Work is tracked in Linear: team **851**, project **lil.tech**.
- Tickets are small and approachable: one focused change that can be reviewed in a few minutes.
- Pick up one ticket at a time:
  1. Move it to In Progress.
  2. Branch off `main` using the ticket's Linear branch name.
  3. Open one PR per ticket, with the ticket ID in the title.
  4. Move the ticket to In Review.
- **Agents work in a worktree per ticket** (851-2884). Create it with `scripts/worktree new <number> <branch>` (`../lil.tech-<number>`, from `origin/main`, warmed). Warming resolves the Swift package into `LilPackage/.build`, the one `swift build`, `swift test` and `scripts/snapshot` use, starting from APFS clones of the last new worktree's (kept in `~/Library/Caches/lil.tech/worktree-package`), so the first build fetches nothing and the step takes seconds (851-2973). It resolves holding `/tmp/xcode-open.lock`, so it waits while Xcode opens a workspace; don't run it while you hold that lock. Always remove it with `scripts/worktree remove <number>`, however the ticket ends (merged, cancelled, blocked or handed back): it deletes Xcode's DerivedData for the worktree too (even a workspace's that never finished loading, which has no `info.plist`, 851-2940), and the branch when nothing on it would be lost (it's in `origin/main`, or its merged or closed PR has every commit). It refuses while there are uncommitted changes; `--stash` stashes them in the main repo. Close the worktree's workspace in Xcode first, or Xcode rebuilds its data. `scripts/worktree prune` lists leftovers, with their PRs' states, and `--apply` removes the merged or closed ones that are clean.
- Run `scripts/format` before committing. `scripts/format --lint` must pass. It covers the Swift code and the TypeScript workspace (`Services/`, `Web/`).
- **Checks run before every commit**, in a [lefthook](https://lefthook.dev) pre-commit hook (`lefthook.yml`). Set it up once per clone: `brew install lefthook`, then `lefthook install`.
  - The hook runs `scripts/check` for the parts a commit touches, with warnings as errors (`CI=1`). `--services`: `scripts/format --lint --services` (format, lint, type checks and a fresh OpenAPI spec), the generated client regenerated and compared (`scripts/generate-api-client --check`), and every workspace package's tests (`vp run -r test` at the root). `--pixelbook`: Pixelbook's graph files against the previews they name.
  - The checks see the working tree, so the hook refuses to run while the paths it checks have unstaged or untracked changes. Stage them, or set them aside with `git stash --keep-index -u`.
  - A failing check blocks the commit. Fix it rather than skipping the hook (`LEFTHOOK=0 git commit …` is for emergencies only).
- **GitHub Actions has two workflows** (851-2826): `.github/workflows/pr.yml` runs everything for a pull request, and `main.yml` everything after a merge. Each starts with a `changes` job (`.github/actions/changes`) that decides which parts are affected; jobs for the other parts are skipped.
  - A PR gets the Swift `check`, a services preview (torn down when the PR closes) and Pixelbook's comment (paused), then `pr-ok`, which passes when every other job passed or was skipped. It's the one required check, set in the "Protect main" ruleset, so a PR can't merge until it passes. The ruleset doesn't require branches to be up to date with `main`, but merge only ones that are (nothing re-checks the TypeScript of a merge that combines changes).
  - A merge deploys staging, then prod, and runs the Swift check again on the merged code. Nothing in `main.yml` is cancelled: deploys queue in the order of the merges.
  - A third, `release.yml`, runs only by hand: it releases lil health (Mac DMG and TestFlight) from `main`, after Alexandru approves the run (the `release` environment, 851-2827). See `docs/RELEASING.md`. Start one only when asked, and never approve its environment gate yourself without his say-so.
- **The Swift checks run on GitHub**, on our Mac minis (`.github/workflows/swift-check.yml`, called by `pr.yml` and `main.yml`, 851-2787), for pull requests and merges to `main` that touch Swift: `scripts/check --swift`, which is Swift lint, the package's tests and the app builds. A new push to a PR cancels its previous check.
  - The minis are self-hosted runners shared with Codevisor (the "Mac minis" runner group). They keep their builds between runs, outside the checkout (`LIL_CHECK_SCRATCH`).
  - The repo is public. A fork's pull request runs no workflow until a maintainer approves it, and it runs its own copy of the workflows, so approving one lets its code run on the minis. Never approve a fork's run that changes `.github/`.
  - Run the same checks locally with `scripts/check --swift`. Its builds go to `.build-check/`, apart from Xcode's and everyday `swift test`'s.
- **Pixelbook's snapshots published before every push, and that's paused** (851-2816): lefthook's `pixelbook` job is skipped and so are the `pixelbook` jobs in `pr.yml` and `main.yml` (`if: false && …`), so pushes don't render or publish snapshots, and PRs get no Pixelbook comment. `scripts/pixelbook publish` still publishes by hand, with the same risk that paused it: an iPhone run can hang, and nothing stops it yet (851-2814). Previews that report an issue aren't caught meanwhile (CI only compiles them). Until it's turned back on, the rest of this bullet describes the hook as it was:
  - It skips with a note, without blocking the push, when it can't publish: offline, no Cloudflare login, uncommitted changes to those inputs, a push of something other than a branch at `HEAD`, or a render that fails for reasons of the machine's (no simulator, a failed build). Publish later with `scripts/pixelbook publish`. Pushes to other remotes are left alone.
  - A preview that reports an issue blocks the push, like a failing check. Fix it; `LEFTHOOK=0 git push` is for emergencies.
  - Push over HTTPS: an SSH connection sits idle while the hook renders, and can drop.
  - **Xcode needs Screen Recording access**, once per Mac (System Settings › Privacy & Security › Screen & System Audio Recording): Pixelbook captures Mac previews that fill a window as the screen shows them. Without it, the hook skips and says so.
  - Each PR gets a comment from `pr.yml`'s `pixelbook` job counting the snapshots that changed since its base, linked to the comparison on pixelbook.lil.tech.
  - Merges to `main` don't push from anyone's machine, so `main.yml`'s `pixelbook` job points `main` at each merge's snapshots, which its branch already published if it was up to date with `main`. Otherwise the run warns, and `main` stays on its last published commit until someone runs `scripts/pixelbook publish` on it.
- Don't bundle unrelated changes. If you find extra work, file a new ticket.

## Building

- Open `Lil.xcworkspace` in Xcode, not the individual `.xcodeproj`.
- From the command line:
  - Package tests: `cd LilPackage && swift test`
  - App: `xcodebuild -workspace Lil.xcworkspace -scheme LilMessages -destination 'platform=macOS,arch=arm64' -skipMacroValidation build`
  - lil health on Mac: `xcodebuild -workspace Lil.xcworkspace -scheme LilHealth -destination 'platform=macOS,arch=arm64' -skipMacroValidation build`
  - lil health on iOS: `xcodebuild -workspace Lil.xcworkspace -scheme LilHealthiOS -destination 'generic/platform=iOS Simulator' -skipMacroValidation build`
- `-skipMacroValidation` skips Xcode's one-time "trust this macro" prompt for package macros (TCA, CasePaths, etc.) in command-line builds; without it, `xcodebuild` fails rather than asking. `swift build` and `swift test` don't validate macros at all.
- **Xcode macro trust.** In Xcode, package macros must be trusted once per version: click the macro error, then "Trust & Enable". After a dependency update, an error saying a macro "was changed since a previous approval" means the new version needs trusting again. Approvals live in `~/Library/org.swift.swiftpm/security/macros.json`, keyed by package, macro target and git revision. If you edit that file, remove stale entries for the same target and restart Xcode, because its build service caches the list.
- **Clocks in tests.** Use `LilTestSupport`'s clocks, not `TestClock` or `ImmediateClock`. `ManualClock` waits until the code under test is asleep before you advance it (`waitUntilAsleep`), since advancing a `TestClock` too early is missed and the sleep never ends. `RecordingClock` returns from sleeps at once and records them; `ImmediateClock`'s sleeps wait on background-priority tasks that busy tests can starve. `eventually` waits for a condition other tasks make true.
- **Objective-C callbacks.** A closure written in `@MainActor` code (a view, a main-actor type) is main-actor-isolated unless its parameter is `@Sendable`. If a framework calls it on another queue, Swift's runtime check crashes the app, and the compiler can't see it, because the callback doesn't say which thread it runs on. That's what crashed lil health after Google sign-in (851-2693).
  - **Risky:** non-`@Sendable` Objective-C blocks, such as `ASWebAuthenticationSession`'s completion handler, and notification subscriptions in SwiftUI or Combine (`.onReceive(NotificationCenter.default.publisher(…))`). Write the closure outside any actor, or add `.receive(on: DispatchQueue.main)` to the publisher, unless the API documents main-thread delivery (e.g. `NSApplication`'s notifications).
  - **`@Sendable` handlers** (KVO's `observe`, `addObserver(forName:…)`) are nonisolated. Hop to the main actor with `Task { @MainActor in … }` rather than `MainActor.assumeIsolated`, which traps if the thread is ever wrong.
  - **Test it:** call the handler from a background `DispatchQueue`, like `WebAuthenticationTests`.
- **Previews of SwiftUI `List`s.** Put a `#Preview` for a view whose `List` uses `ForEach` rows in a separate `*Previews.swift` file. Previewing a file instruments its functions, and with `ForEach` rows that trips an assertion in SwiftUI's macOS `List` (`TableViewListCore_Mac2`).
- **Xcode MCP.** `.mcp.json` registers Xcode's MCP server (`xcrun mcpbridge`), which provides tools like `RenderPreview`. Approve it when Claude Code first asks. It talks to the running Xcode, so keep Xcode open with `Lil.xcworkspace`, and allow external agents in Xcode › Settings › Intelligence. `xcrun` uses whichever Xcode `xcode-select` points at.
- **Preview snapshots.** Xcode's `RenderPreview` (MCP) snapshots a preview's first frame, before `.task` runs. Give previews their data in the initial state, using `makePreviewChatDatabase()` from `MessagesDatabase`, so snapshots show real content. That demo dataset is for previews only; tests seed their own data. For a state that a view's `.task` would immediately replace (empty, checking access), build the store with `EmptyReducer()`.

### Without Xcode

Building, running and inspecting the apps all work from the command line (851-2956). Still Xcode-only, and rarely needed: the canvas's live interaction, the view and memory graph debuggers, and Instruments' UI (`xctrace` records, Instruments shows). To check UI, prefer snapshot tests (`HealthSnapshotTests`) to screenshots of a running app.

- **Build** into a folder of the worktree, so the app's path is known and `scripts/worktree remove` deletes it. Not `.build-check/`, where `scripts/check` builds unsigned: an unsigned app can't keep its session in the Keychain.
  ```sh
  xcodebuild -workspace Lil.xcworkspace -scheme LilHealth -destination 'platform=macOS,arch=arm64' \
    -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile -derivedDataPath .build/DerivedData \
    build -quiet
  app="$PWD/.build/DerivedData/Build/Products/Debug/lil health.app"
  ```
  - The simulator's: `-scheme LilHealthiOS -destination 'generic/platform=iOS Simulator'`, into `Debug-iphonesimulator/`. A device's: `-destination 'generic/platform=iOS'`, into `Debug-iphoneos/`.
  - Without `-derivedDataPath`, builds go to `~/Library/Developer/Xcode/DerivedData/Lil-<hash>`. `platform=macOS` alone warns that two destinations match (arm64 and x86_64). `-onlyUsePackageVersionsFromResolvedFile` keeps a fresh folder's resolve from changing `Package.resolved`, as `scripts/check` does.
- **Run the Mac app** in a temporary home against a PR preview, signed in to its test account (synthetic data only):
  ```sh
  home=$(mktemp -d)
  open -n "$app" --env CFFIXED_USER_HOME="$home" --env LIL_API_URL=https://…workers.dev \
    --env LIL_SIGN_IN_TO_TEST_ACCOUNT=1
  pid=$(pgrep -f "$app/Contents/MacOS/lil health")
  ```
  - **A dev build's local data is its own too** (851-2977). Release builds keep today's folder, `~/Library/Application Support/tech.lil.health` (and `~/Library/Caches/tech.lil.health/LilSync`, `UserDefaults.standard`). Debug Mac and simulator builds keep a folder per server inside each, prod's included (`tech.lil.health/Servers/api.staging.lil.tech`), and a user defaults suite per server (`tech.lil.health.Servers.api.staging.lil.tech`). So a dev build that opens signed out, which deletes the account's data (health data, agent access setting and log), never deletes the installed app's, even in your own home. `lil-health` finds the same folder from the `LIL_API_URL` it forwards.
  - **Still use a temporary home** for scripted runs: every dev build against one server shares that server's folder, so in your own home a run signing out of staging deletes what another run (or agent) synced from it, and its files outlive the run. A temporary home keeps each run's files to itself (`$home/Library/Application Support/tech.lil.health/Servers/<server>`), and deleting it cleans up.
  - **A dev build's session is its own** (851-2974). Release builds (and iPhone builds on a device), which only use prod, keep the item every build used before (service `tech.lil.auth`, account `session`). Simulator and Debug Mac builds have one item per server, with the server's origin in the account (`session https://api.staging.lil.tech`), prod's included. So a dev build never sees, replaces or signs out the Release app's session, and running one on a Mac where lil health is signed in to a real account is fine. Each dev build against a server shares that server's item.
  - The items are in the data protection Keychain, which `security find-generic-password` can't see.
  - Sign out before quitting, so the next build against that preview doesn't start signed in, and its item doesn't outlive the preview: lil health › Sign Out, or `osascript -e "tell application \"System Events\" to click menu item \"Sign Out\" of menu 1 of menu bar item 2 of menu bar 1 of (first process whose unix id is $pid)"`, which needs Accessibility access for the terminal. Check that the window shows the sign-in screen, then `kill $pid`.
  - Without `LIL_API_URL`, a Debug build uses staging. Release builds ignore it and use prod.
- **Inspect by `$pid`,** not the name "lil health", which an installed copy shares.
- **Logs:** `/usr/bin/log stream --style compact --predicate "processID == $pid"`, or `log show --last 10m …` for the past. Spell out `/usr/bin/log`: zsh has a `log` builtin. Our own loggers use `subsystem == "tech.lil.health"` (the iPhone's backfill, uploads and synthetic data); the Mac app has none yet, so its log is the system frameworks'. Issues `reportIssue` raises are logged as `subsystem == "com.apple.runtime-issues"`, with the module as the category and the message redacted.
- **Debug** a Debug build: `lldb -p $pid`. For a one-shot look, `lldb --batch -p $pid -o 'bt all' -o detach`. Over SSH it can't attach ("cannot get permission to debug processes") unless Developer Mode is on (`DevToolsSecurity -enable`, an administrator's), which it isn't on the minis.
- **Profile:** `xcrun xctrace record --template 'Time Profiler' --attach $pid --time-limit 10s --output /tmp/lil.trace`. Saving takes a minute or more. `xcrun xctrace export --input /tmp/lil.trace --toc` lists its tables, and `--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` exports the samples as XML. `open /tmp/lil.trace` shows it in Instruments. A trace records the app's whole environment, so never attach one anywhere public.
- **Screenshots** of a running Mac app need Screen Recording access for the terminal: without it, as over SSH on the minis, window titles read `undefined` and `screencapture` fails ("could not create image from window"). They show Liquid Glass, which snapshot tests can't. Find the window's number, then capture it:
  ```sh
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))).filter(w => w.kCGWindowOwnerPID == '$pid' && w.kCGWindowLayer == 0).map(w => w.kCGWindowNumber + " " + w.kCGWindowName).join("\n")'
  screencapture -o -x -l <number> window.png
  ```
- **iPhone simulator:** use a simulator of your own, by its UDID, since other agents' may be booted. Its Keychain is its own, and deleting it cleans up everything. Within it, each server's session is its own too, as on the Mac.
  ```sh
  sim=$(xcrun simctl create lil-dev "iPhone 18 Pro")
  xcrun simctl bootstatus "$sim" -b
  xcrun simctl install "$sim" "$PWD/.build/DerivedData/Build/Products/Debug-iphonesimulator/lil health.app"
  SIMCTL_CHILD_LIL_API_URL=https://…workers.dev SIMCTL_CHILD_LIL_SIGN_IN_TO_TEST_ACCOUNT=1 \
    xcrun simctl launch --terminate-running-process "$sim" tech.lil.health   # prints its pid
  xcrun simctl io "$sim" screenshot screen.png
  xcrun simctl spawn "$sim" log stream --style compact --predicate 'subsystem == "tech.lil.health"'
  xcrun simctl delete "$sim"   # when done
  ```
  On a busy Mac, booting can fail ("launchd_sim may have crashed"): run `bootstatus` again.
- **iPhone:** device builds always use prod, with real Health data, so only on your own device and account. `xcrun devicectl list devices` shows each one's identifier. Then `xcrun devicectl device install app --device <id> "$PWD/.build/DerivedData/Build/Products/Debug-iphoneos/lil health.app"` and `xcrun devicectl device process launch --device <id> tech.lil.health`.
- **Stale builds in LaunchServices.** Every build that runs is registered with LaunchServices, and stays registered after its folder is deleted. Shortcuts and `lil` look the app up by its bundle ID there, so they can pick another copy (851-2894). After `scripts/worktree remove`, unregister the copies that are gone, with the Sparkle updaters inside them:
  ```sh
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$lsregister" -dump | sed -nE 's/^path: +(.*\/lil (health|messages)\.app(\/.*\.app)?) \(0x[0-9a-f]+\)$/\1/p' | sort -u |
    while IFS= read -r stale; do [ -e "$stale" ] || "$lsregister" -u "$stale"; done
  ```
  `"$lsregister" -u <path>` unregisters one copy that's still there, and `"$lsregister" -f "$app"` registers the one under test.

## TypeScript (Services/ and Web/)

- The repo root is a pnpm workspace managed by [Vite+](https://viteplus.dev/guide/), with servers in `Services/` (the API, `Services/api`) and web projects in `Web/` (the website, `Web/site`, and Pixelbook, `Web/pixelbook`). Install the `vp` CLI (`brew install vite-plus`), then run `vp install` at the root.
- Node is pinned in `.node-version`, and pnpm in `package.json`, both at the root.
- Dependency versions live only in the catalog in `pnpm-workspace.yaml`. Packages refer to them as `catalog:`. Add dependencies with `vp add <pkg>@catalog:` after adding them to the catalog, and never install `@latest` (even where the `effect-ts` skill's setup steps say to).
- Check and test:
  - `vp check`: format, lint and type check.
  - `vp run -r test`: every package's tests.
  - In a package, e.g. `Services/api`: `vp test`.
- Lint and format settings live only in the root `vite.config.ts`. Vite+ doesn't apply per-package lint or format configs. The formatter ignores everything outside the workspace (Swift, Apple config files, docs).
- Vite+'s own docs ship in `node_modules/vite-plus/docs`.

### API contract

- `Services/api/openapi.json` is the API's OpenAPI spec, generated from the HttpApi definition by `Services/api/scripts/openapi.ts` and served at `/v1/openapi.json`. Generated clients (the Swift `LilAPI` module) are built from the committed file.
- The Swift client is generated from that file into `LilPackage/Sources/LilAPIGenerated/Generated` by `scripts/generate-api-client`, which runs Apple's swift-openapi-generator pinned in `Tools/Package.swift`. Don't edit generated files.
- `scripts/format` regenerates both the spec and the client, in that order, and `scripts/format --lint` fails if either is stale. Commit them with any API change.
- `Services/api/mcp-tools.json` is the Health toolkit's MCP tool definitions (`tools/list`), generated from `src/health/tools/HealthToolkit.ts` by `Services/api/scripts/mcp-tools.ts`. The Mac's `lil-health mcp` registers its tools from it. `scripts/format` regenerates it and `--lint` fails if it's stale.
- `Services/api/health-catalog.json` is the server's copy of the Swift `HealthCatalog`, its source of truth, generated by `scripts/generate-health-catalog` (`scripts/format`'s Swift part). Edit the Swift catalog, never the file: `scripts/format --lint` and `HealthCatalogTests` fail if it's stale.
- **Core D1 schema:** `Services/api/src/core/Schema.ts` (Drizzle). `scripts/format` generates a migration into `Services/api/migrations/core` when it changes, and `scripts/format --lint` fails if one is missing. Commit generated migrations with the schema change, and don't edit applied ones. SQL Drizzle can't express (triggers) goes at the end of a generated `migration.sql`, after a `--> statement-breakpoint` line.
- **Compatibility:** installed apps keep running old clients.
  - Adding response fields is safe, because the spec allows additional properties.
  - Adding a case to a response enum, or removing or renaming anything, breaks them. Add a new field or a new endpoint instead.
  - `scripts/format --lint` fails if the spec is stale, or if the client's stamp doesn't match the spec, generator pin and config. The pre-commit hook also regenerates the client into a temporary directory and compares it (`scripts/generate-api-client --check`), which catches hand edits too.
- Apps use the client through `@Dependency(\.api)` (from `LilAPI`). Tests get a client that fails every request and reports an issue; answer requests with `Client.mock { request, body in … }`. `LIL_API_URL` in a scheme's environment points an app at another deployment, such as a PR preview.

### Deploying the API

- The API is an Alchemy stack in `Services/api/alchemy.run.ts`. The same stack deploys the website, `Web/site/public` (static files, such as the privacy policy), to `lil.tech` in prod, `staging.lil.tech` in staging, and workers.dev elsewhere. It also deploys Pixelbook (`Web/pixelbook`, a TanStack Start app) to `pixelbook.lil.tech` and `pixelbook.staging.lil.tech`. Run it locally with `vp dev` in `Web/pixelbook`: it reads the published snapshots. Its state lives in Cloudflare (an `alchemy-state-store` Worker in account 851), so every machine and CI share it.
- Run Alchemy from `Services/api` (`npx alchemy …`), where it's installed. From anywhere else, `npx` fetches a separate copy that can't find its peer dependencies.
- **Credentials:** once per machine, from `Services/api`, run `ALCHEMY_TUI=1 DO_NOT_TRACK=1 npx alchemy profile edit --add Cloudflare`. Choose OAuth, then **Basic Scopes**, then sign in with a Cloudflare user that's a member of account **851**, and pick that account. Credentials are saved in `~/.alchemy/profiles.json`. Alchemy hides its interactive prompts when it detects a coding agent, and `ALCHEMY_TUI=1` shows them again. Check credentials with `npx alchemy profile show`. The bare `npx alchemy profile` dashboard crashes in this beta, because `react` isn't installed.
- **Telemetry:** Alchemy reports usage to `otel.alchemy.run` unless `DO_NOT_TRACK=1` is set. Set it in your shell.
- **CI** (`.github/workflows/pr.yml` and `main.yml`) deploys changes to the TypeScript workspace (`Services/`, `Web/`, the root config). Its checks run in the pre-commit hook instead.
  - Pull requests are deployed to a preview stage, `pr-<number>`, on workers.dev. A PR comment links the preview.
  - Closing a PR destroys its preview, including R2 buckets that still hold objects. Every bucket is a `DisposableBucket` (`src/Deployment.ts`), which sets `forceDestroy` everywhere but staging and prod. If the teardown fails, the job comments on the PR. Fix the cause and rerun the failed job. Destroy uses the props saved at the stage's last deploy, so a stage deployed before a props change needs its bucket emptied by hand.
  - To try a preview as a signed-in user, `POST /v1/auth/dev` (optionally with `{"displayName": "…"}`) creates a synthetic user and returns tokens. With `{"account": "…"}` it signs in to the synthetic user of that name, made the first time, so several devices share it. The route only exists in the `preview` environment (PR previews, and personal stages from `vp run deploy`, named `live_<user>`) and the `local` one (`alchemy dev`, `dev_<user>`). Each stage allows at most 1,000 users.
  - The apps sign in the same way: a simulator or Debug Mac build pointed at a preview (`LIL_API_URL`) shows **Sign in to a Test Account**, which signs in to the account `e2e`. An iPhone simulator and the Mac then share it.
  - For scripts, `LIL_SIGN_IN_TO_TEST_ACCOUNT=1` in the environment does the same when the app opens signed out, e.g. `open -n --env LIL_API_URL=… --env LIL_SIGN_IN_TO_TEST_ACCOUNT=1 "lil health.app"` (or `SIMCTL_CHILD_LIL_SIGN_IN_TO_TEST_ACCOUNT=1 xcrun simctl launch …`).
  - Merging to `main` deploys staging, then prod, and `scripts/check-deploy` waits until each serves the new commit.
  - CI authenticates with the `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repo secrets (token "lil.tech CI (Alchemy deploys)": account 851, zone `lil.tech`).
  - The `LIL_APPLE_SIGN_IN_KEY` repo secret, the Sign in with Apple key, and `LIL_GOOGLE_WEB_CLIENT_SECRET`, the agents' authorization page's Google client secret, go to staging and prod deploys only.
  - Previews run PR code with that deploy token, and Cloudflare can't limit `Workers Scripts:Edit` to particular Workers. Only branches pushed to this repo get previews (fork PRs get no secrets), so only give push access to people you'd trust with prod.
- **Deploying by hand** (from `Services/api`), rarely needed since CI deploys `main`:
  - `vp run deploy:staging` deploys to `api.staging.lil.tech`.
  - `vp run deploy:prod` deploys to `api.lil.tech`.
  - Staging and prod need the Sign in with Apple key in `LIL_APPLE_SIGN_IN_KEY`, e.g. `LIL_APPLE_SIGN_IN_KEY="$(op document get 'lil health – Sign in with Apple key (J59CSK4YXA)')" vp run deploy:prod`, and the Google web client's secret in `LIL_GOOGLE_WEB_CLIENT_SECRET`, e.g. `LIL_GOOGLE_WEB_CLIENT_SECRET="$(op read 'op://Private/s2xhneqrvpdb2vlkit6zhpn5wy/client secret')"` (the item "lil health – Google web OAuth client (agent sign-in)", read by its ID since `op read` trips on the dash).
  - `vp run deploy` deploys your personal stage, on workers.dev only.
  - `node scripts/notifications.ts` applies the account's billing and usage notification policies. They're account-wide, so no stage deploys them. See `docs/decisions/server.md` for credentials.
  - Each script sets `LIL_ENVIRONMENT` and `LIL_VERSION` (the git SHA, with `-dirty` for uncommitted changes), which the Worker reads at deploy time. Deploy prod from a clean tree.
- A Worker's props Effect runs at deploy **and** inside the running Worker, where Alchemy services like `Stage` don't exist. Read them with `Effect.serviceOption`.
- **Alchemy is in beta and pinned exactly** (`alchemy` in the catalog). Before writing Alchemy code, look resources and APIs up in [alchemy.run/llms.txt](https://alchemy.run/llms.txt) (and `llms-full.txt`). If they disagree with the installed types in `Services/api/node_modules/alchemy`, the installed types win. Don't install third-party Alchemy skills.
- **Logical IDs must be unique in the stack,** across resource types. Alchemy doesn't reject a repeated ID: it returns the existing resource, so the second one is never created (a Worker given a bucket's ID wasn't deployed, with only a `noop` in the log). Renaming a deployed resource's ID replaces it, unless you add `.pipe(Alchemy.renamedFrom("OldId"))`, which moves its state to the new ID.
- Workers with stage-dependent props (e.g. a domain per stage) use the class form, `Cloudflare.Worker<Self>()(id, propsEffect, impl)`. The plain `Cloudflare.Worker(id, props, impl)` form only accepts plain props.
- Alchemy's Effect Worker entry imports the module's **default** export, so Worker modules `export default class … extends Cloudflare.Worker<…>()(…)`.
- An `HttpApiBuilder` layer in a Worker gets its platform services from Alchemy's `Http.Platform` (`alchemy/Http`), which includes the no-op `FileSystem` Workers need.

### Learning more about Effect

This repository uses the Effect TypeScript library. The `effect-ts` skill (`.claude/skills/effect-ts`) sets this up.

Before writing any Effect code, first read `node_modules/effect/AGENTS.md` **completely**, and follow the links in the file when required.

If you need to learn more about particular Effect APIs and concepts that the guide doesn't cover, search through the source code in `node_modules/effect/src`.

## Previews

All visual validation goes through SwiftUI previews rendered with `RenderPreview`, not by running the app.

- Every feature has a preview for each state of its state machine: loaded, empty, loading, failed, pending, and edge-case content. Screens migrated to state catalogs (851-2949; the screens in `HealthSnapshotTests/Catalogs/`, and the iPhone's in `HealthPhoneSnapshotTests/Catalogs/`, 851-2953) have catalog states instead, and no previews: check them with `scripts/snapshot` (`--iphone` for the iPhone's), not `RenderPreview`.
- A UI change comes with previews for each state it affects. Render them, check the snapshots, and attach them to both the PR and the Linear ticket (as a comment).
- `scripts/contact-sheet <out.png> <columns> <images…>` combines snapshots into one labeled image for the ticket.
- **Mac preview sizes:** use `previewFrame(width:height:)`, not `.frame(width:height:)`. Pixelbook's snapshots grow a preview to show all of its scroll content, and a fixed height leaves a blank band above it instead.
- **Snapshot tests** (851-2931): `HealthSnapshotTests` renders some Mac preview states with swift-snapshot-testing in plain `swift test`, without Xcode, and compares them with the PNGs in its `__Snapshots__` folders, pixel for pixel, though a pixel's channels may be 1 apart (851-2985): macOS 27.0 and 27.0.1 draw some gradients and symbols that far apart. Run them with `cd LilPackage && swift test --filter HealthSnapshotTests`, which takes seconds once built, and opens no window.
  - **State catalogs** (851-2949) replace a screen's `#Preview`s: `Catalogs/<Module>/<Screen>Catalog.swift` in the test target, e.g. `Catalogs/HealthMacApp/MetricDetailCatalog.swift`, the example to copy. A `StateCatalog` is a screen's name, a default width and minimum height, and `CatalogState`s: a name, optionally its own size, and a closure building the view from synthetic data, `previewNow` and `previewCalendar`. One parameterized test, in an `extension MacSnapshotTests` (whose `.dependencies` trait gives the catalog database, date and calendar), calls `state.assertMacSnapshots()` for its states in light and dark. The view is the state's width, top-aligned, at least its height and growing to its content, so catalogs need no `previewFrame`. References are `__Snapshots__/<Screen>Catalog/<screen>.<state>-<light|dark>.png` next to the catalog, named by slugs of the names (`Steps, 6 months` is `steps-6-months`), so renaming a state renames its references: delete the old ones.
  - **Migrating a screen:** (1) make the views its states render read the date and calendar from `@Dependency(\.date.now)` and `@Dependency(\.calendar)` (or take them), never `.now` or `Calendar.current`; (2) copy each `#Preview` into a `CatalogState` of the same name, its `previewFrame` size becoming the state's or the catalog's, `.now` and `.current` becoming `previewNow` and `previewCalendar`, and `makePreviewHealthDatabase()` becoming `catalogDatabase`; (3) `scripts/snapshot --record <test>`, then read every image; (4) delete the previews file, and helpers only it used; (5) point the screen in `Web/pixelbook/graphs/*.json` at the catalog, `Module/<Screen>Catalog.swift`, which `scripts/check --pixelbook` checks; (6) a new `Catalogs/<Module>` folder adds its `__Snapshots__` to the target's `exclude` in `Package.swift`.
  - A change to a snapshotted view fails its test, which says where the new image is. Check it, then re-record: delete the reference and run again, or run with `SNAPSHOT_TESTING_RECORD=failed`. Commit the new references with the change.
  - **While working on a view, use `scripts/snapshot <test>`** (851-2962), e.g. a catalog's test, `scripts/snapshot metricDetail`, with `LIL_SNAPSHOT_STATE=<regular expression>` for some of its states, matched against their names, ignoring case (`LIL_SNAPSHOT_STATE=loading scripts/snapshot metricDetail`). It builds what `swift test` builds, in the same `.build`, then runs only the snapshot tests, filtered like `swift test --filter`, which saves `swift test` starting every test bundle twice. About 6 s from an edit to compared images on a quiet Mac, against 9 s (`docs/BENCHMARK.md`); on a busy one, about as long as a warm `RenderPreview`. It works without a TTY.
    - Every image it takes goes to `LilPackage/.build/snapshots/<test file>/` (`MetricDetailCatalog/`), changed or not, byte for byte what `swift test` takes. It prints each one's path, with `matches`, `differs`, `recorded`, `rerecorded` or `failed`; one that differs also gets its reference's path, a count of the pixels more than 1 apart, the largest difference and where they are, and a `.diff.png` with them in red. Read the images to check them.
    - `--record` re-records what changed (`SNAPSHOT_TESTING_RECORD=failed`), and exits zero unless something else failed. `--no-build` reruns what was last built. It exits non-zero when an image differs or a test fails.
  - The images match `RenderPreview`'s in fonts, lists, forms, charts, sizes and dark mode, but not Liquid Glass, which only draws on screen: toolbar controls, a switch's tint and the window buttons. Check those in `RenderPreview`.
  - **iPhone catalogs** (851-2953) are in `HealthPhoneSnapshotTests` (`LilPackage/Tests/HealthPhoneSnapshotTests`), which isn't a SwiftPM target: an app hosts it in the simulator (`PhoneSnapshotHost`, in `Tools/PhoneSnapshots/PhoneSnapshots.xcodeproj`, part of `Lil.xcworkspace`), so it draws through the window server, and Liquid Glass renders. A catalog is `StateCatalog(phone:states:)`, its states full screen, with a test calling `state.assertPhoneSnapshots()` in an `extension PhoneSnapshotTests`: copy `Catalogs/HealthPhoneApp/SyncStatusCatalog.swift`. The migration steps are the Mac's, except the last: the project picks up new files itself (a synchronized folder), and leaves references out of the test bundle by their extension (`EXCLUDED_SOURCE_FILE_NAMES = *.png`), so `Package.swift` doesn't change. Unlike the Mac's, a state is shown on screen for half a second before it's drawn, so its `.task` runs: build stores with `EmptyReducer`, as `SyncStatusCatalog` does.
    - Run them with `scripts/snapshot --iphone [<test>]`, e.g. `scripts/snapshot --iphone syncStatus`, with `--record`, `--no-build` and `LIL_SNAPSHOT_STATE` as for the Mac. A test is named, not matched. Images go to `LilPackage/.build/snapshots-iphone/<test file>/`, and match within 2 per color channel (`phoneChannelTolerance`; the Mac's within 1), since glass comes out up to 2 apart between runs.
    - It uses a simulator of its own, `lil-snapshots`, an iPhone 18 Pro on iOS 27.0 so every Mac renders the same images. It's made when missing, booted while the build runs and left booted for the next run; `scripts/snapshot --iphone --delete-simulator` deletes it. Boots are retried, and a test run still going after 5 minutes is stopped and tried once more. One run at a time per Mac: others wait.
    - Times are in `docs/BENCHMARK.md`. GitHub runs it after every merge to `main` (`iphone-snapshots` in `swift-check.yml`); pull requests' `check` only compiles it (`scripts/check --swift`). Run it yourself when you change an iPhone screen.
  - Synthetic data and fixed dates only, since the images are committed and must be the same every day.

## Privacy: user data

This repo is public. lil messages reads `~/Library/Messages/chat.db`, and dev machines with Full Disk Access can read the real file. lil health reads Apple Health on a developer's iPhone and stores it on our servers.

- **Never** commit `chat.db`, copies of it, or anything extracted from it.
- Reading the real `chat.db` locally to debug or explore is fine. Just never let its contents end up in commits, PRs, tickets, or other public places.
- Test fixtures and previews use synthetic data only, e.g. built from hand-written SQL.
- Before committing, check that no `.db` files or real message content are staged.
- **Health data** follows the same rules. Never commit, paste or attach real Health data (exports, samples, screenshots of real values, server rows), and never copy it into staging or preview environments.
- Testing lil health on your own iPhone is fine. Device builds talk to prod, so your real data stays in your own prod account. Simulator builds talk to staging or a PR preview, which only ever get synthetic data. Use synthetic data in tests, previews and tickets.
