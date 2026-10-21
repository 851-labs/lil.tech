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
- **Agents work in a worktree per ticket** (851-2884). Create it with `scripts/worktree new <number> <branch>` (`../lil.tech-<number>`, from `origin/main`, warmed). Always remove it with `scripts/worktree remove <number>`, however the ticket ends (merged, cancelled, blocked or handed back): it deletes Xcode's DerivedData for the worktree too, and the branch when nothing on it would be lost (it's in `origin/main`, or its merged or closed PR has every commit). It refuses while there are uncommitted changes; `--stash` stashes them in the main repo. Close the worktree's workspace in Xcode first, or Xcode rebuilds its data. `scripts/worktree prune` lists leftovers, with their PRs' states, and `--apply` removes the merged or closed ones that are clean.
- Run `scripts/format` before committing. `scripts/format --lint` must pass. It covers the Swift code and the TypeScript workspace (`Services/`, `Web/`).
- **Checks run before every commit**, in a [lefthook](https://lefthook.dev) pre-commit hook (`lefthook.yml`). Set it up once per clone: `brew install lefthook`, then `lefthook install`.
  - The hook runs `scripts/check` for the parts a commit touches, with warnings as errors (`CI=1`). `--services`: `scripts/format --lint --services` (format, lint, type checks and a fresh OpenAPI spec), the generated client regenerated and compared (`scripts/generate-api-client --check`), and every workspace package's tests (`vp run -r test` at the root). `--pixelbook`: Pixelbook's graph files against the previews they name.
  - The checks see the working tree, so the hook refuses to run while the paths it checks have unstaged or untracked changes. Stage them, or set them aside with `git stash --keep-index -u`.
  - A failing check blocks the commit. Fix it rather than skipping the hook (`LEFTHOOK=0 git commit …` is for emergencies only).
- **GitHub Actions has two workflows** (851-2826): `.github/workflows/pr.yml` runs everything for a pull request, and `main.yml` everything after a merge. Each starts with a `changes` job (`.github/actions/changes`) that decides which parts are affected; jobs for the other parts are skipped.
  - A PR gets the Swift `check`, a services preview (torn down when the PR closes) and Pixelbook's comment (paused), then `pr-ok`, which passes when every other job passed or was skipped. Wait for a PR's `pr-ok` to pass before merging it. It's the one check branch protection needs, though it isn't required yet.
  - A merge deploys staging, then prod, and runs the Swift check again on the merged code. Nothing in `main.yml` is cancelled: deploys queue in the order of the merges.
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
  - App: `xcodebuild -workspace Lil.xcworkspace -scheme LilMessages -destination 'platform=macOS' -skipMacroValidation build`
  - lil health on Mac: `xcodebuild -workspace Lil.xcworkspace -scheme LilHealth -destination 'platform=macOS' -skipMacroValidation build`
  - lil health on iOS: `xcodebuild -workspace Lil.xcworkspace -scheme LilHealthiOS -destination 'generic/platform=iOS Simulator' -skipMacroValidation build`
- `-skipMacroValidation` skips Xcode's one-time "trust this macro" prompt for package macros (TCA, CasePaths, etc.) in command-line builds.
- **Xcode macro trust.** In Xcode, package macros must be trusted once per version: click the macro error, then "Trust & Enable". After a dependency update, an error saying a macro "was changed since a previous approval" means the new version needs trusting again. Approvals live in `~/Library/org.swift.swiftpm/security/macros.json`, keyed by package, macro target and git revision. If you edit that file, remove stale entries for the same target and restart Xcode, because its build service caches the list.
- **Clocks in tests.** Use `LilTestSupport`'s clocks, not `TestClock` or `ImmediateClock`. `ManualClock` waits until the code under test is asleep before you advance it (`waitUntilAsleep`), since advancing a `TestClock` too early is missed and the sleep never ends. `RecordingClock` returns from sleeps at once and records them; `ImmediateClock`'s sleeps wait on background-priority tasks that busy tests can starve. `eventually` waits for a condition other tasks make true.
- **Objective-C callbacks.** A closure written in `@MainActor` code (a view, a main-actor type) is main-actor-isolated unless its parameter is `@Sendable`. If a framework calls it on another queue, Swift's runtime check crashes the app, and the compiler can't see it, because the callback doesn't say which thread it runs on. That's what crashed lil health after Google sign-in (851-2693).
  - **Risky:** non-`@Sendable` Objective-C blocks, such as `ASWebAuthenticationSession`'s completion handler, and notification subscriptions in SwiftUI or Combine (`.onReceive(NotificationCenter.default.publisher(…))`). Write the closure outside any actor, or add `.receive(on: DispatchQueue.main)` to the publisher, unless the API documents main-thread delivery (e.g. `NSApplication`'s notifications).
  - **`@Sendable` handlers** (KVO's `observe`, `addObserver(forName:…)`) are nonisolated. Hop to the main actor with `Task { @MainActor in … }` rather than `MainActor.assumeIsolated`, which traps if the thread is ever wrong.
  - **Test it:** call the handler from a background `DispatchQueue`, like `WebAuthenticationTests`.
- **Previews of SwiftUI `List`s.** Put a `#Preview` for a view whose `List` uses `ForEach` rows in a separate `*Previews.swift` file. Previewing a file instruments its functions, and with `ForEach` rows that trips an assertion in SwiftUI's macOS `List` (`TableViewListCore_Mac2`).
- **Xcode MCP.** `.mcp.json` registers Xcode's MCP server (`xcrun mcpbridge`), which provides tools like `RenderPreview`. Approve it when Claude Code first asks. It talks to the running Xcode, so keep Xcode open with `Lil.xcworkspace`, and allow external agents in Xcode › Settings › Intelligence. `xcrun` uses whichever Xcode `xcode-select` points at.
- **Preview snapshots.** Xcode's `RenderPreview` (MCP) snapshots a preview's first frame, before `.task` runs. Give previews their data in the initial state, using `makePreviewChatDatabase()` from `MessagesDatabase`, so snapshots show real content. That demo dataset is for previews only; tests seed their own data. For a state that a view's `.task` would immediately replace (empty, checking access), build the store with `EmptyReducer()`.

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

- Every feature has a preview for each state of its state machine: loaded, empty, loading, failed, pending, and edge-case content.
- A UI change comes with previews for each state it affects. Render them, check the snapshots, and attach them to both the PR and the Linear ticket (as a comment).
- `scripts/contact-sheet <out.png> <columns> <images…>` combines snapshots into one labeled image for the ticket.
- **Mac preview sizes:** use `previewFrame(width:height:)`, not `.frame(width:height:)`. Pixelbook's snapshots grow a preview to show all of its scroll content, and a fixed height leaves a blank band above it instead.

## Privacy: user data

This repo is public. lil messages reads `~/Library/Messages/chat.db`, and dev machines with Full Disk Access can read the real file. lil health reads Apple Health on a developer's iPhone and stores it on our servers.

- **Never** commit `chat.db`, copies of it, or anything extracted from it.
- Reading the real `chat.db` locally to debug or explore is fine. Just never let its contents end up in commits, PRs, tickets, or other public places.
- Test fixtures and previews use synthetic data only, e.g. built from hand-written SQL.
- Before committing, check that no `.db` files or real message content are staged.
- **Health data** follows the same rules. Never commit, paste or attach real Health data (exports, samples, screenshots of real values, server rows), and never copy it into staging or preview environments.
- Testing lil health on your own iPhone is fine. Device builds talk to prod, so your real data stays in your own prod account. Simulator builds talk to staging or a PR preview, which only ever get synthetic data. Use synthetic data in tests, previews and tickets.
