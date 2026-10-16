# AGENTS.md

Read `docs/DECISIONS.md` before starting work. It records every architecture and product decision made so far.

## Workflow

- Work is tracked in Linear: team **851**, project **lil.tech**.
- Tickets are small and approachable: one focused change that can be reviewed in a few minutes.
- Pick up one ticket at a time:
  1. Move it to In Progress.
  2. Branch off `main` using the ticket's Linear branch name.
  3. Open one PR per ticket, with the ticket ID in the title.
  4. Move the ticket to In Review.
- Run `scripts/format` before committing. `scripts/format --lint` must pass. It covers the Swift code and the TypeScript in `Services/`.
- **Checks run before every commit**, in a [lefthook](https://lefthook.dev) pre-commit hook (`lefthook.yml`), not on GitHub. Set it up once per clone: `brew install lefthook`, then `lefthook install`.
  - The hook runs `scripts/check` for the parts a commit touches, with warnings as errors (`CI=1`). `--swift`: Swift lint, the package's tests and both app builds. `--services`: `scripts/format --lint --services` (format, lint, type checks and a fresh OpenAPI spec), the generated client regenerated and compared (`scripts/generate-api-client --check`), and every Services package's tests.
  - Its builds go to `.build-check/`, apart from Xcode's and everyday `swift test`'s, so the first run after cloning is slow and later ones take about a minute.
  - The checks see the working tree, so the hook refuses to run while the paths it checks have unstaged or untracked changes. Stage them, or set them aside with `git stash --keep-index -u`.
  - A failing check blocks the commit. Fix it rather than skipping the hook (`LEFTHOOK=0 git commit …` is for emergencies only).
  - The Swift workflow (`.github/workflows/swift.yml`) is off for now. It can still be run by hand from the Actions tab.
- Don't bundle unrelated changes. If you find extra work, file a new ticket.

## Building

- Open `Lil.xcworkspace` in Xcode, not the individual `.xcodeproj`.
- From the command line:
  - Package tests: `cd LilPackage && swift test`
  - App: `xcodebuild -workspace Lil.xcworkspace -scheme LilMessages -destination 'platform=macOS' -skipMacroValidation build`
  - lil health on iOS: `xcodebuild -workspace Lil.xcworkspace -scheme LilHealthiOS -destination 'generic/platform=iOS Simulator' -skipMacroValidation build`
- `-skipMacroValidation` skips Xcode's one-time "trust this macro" prompt for package macros (TCA, CasePaths, etc.) in command-line builds.
- **Xcode macro trust.** In Xcode, package macros must be trusted once per version: click the macro error, then "Trust & Enable". After a dependency update, an error saying a macro "was changed since a previous approval" means the new version needs trusting again. Approvals live in `~/Library/org.swift.swiftpm/security/macros.json`, keyed by package, macro target and git revision. If you edit that file, remove stale entries for the same target and restart Xcode, because its build service caches the list.
- **Previews of SwiftUI `List`s.** Put a `#Preview` for a view whose `List` uses `ForEach` rows in a separate `*Previews.swift` file. Previewing a file instruments its functions, and with `ForEach` rows that trips an assertion in SwiftUI's macOS `List` (`TableViewListCore_Mac2`).
- **Xcode MCP.** `.mcp.json` registers Xcode's MCP server (`xcrun mcpbridge`), which provides tools like `RenderPreview`. Approve it when Claude Code first asks. It talks to the running Xcode, so keep Xcode open with `Lil.xcworkspace`, and allow external agents in Xcode › Settings › Intelligence. `xcrun` uses whichever Xcode `xcode-select` points at.
- **Preview snapshots.** Xcode's `RenderPreview` (MCP) snapshots a preview's first frame, before `.task` runs. Give previews their data in the initial state, using `makePreviewChatDatabase()` from `MessagesDatabase`, so snapshots show real content. That demo dataset is for previews only; tests seed their own data. For a state that a view's `.task` would immediately replace (empty, checking access), build the store with `EmptyReducer()`.

## Services (TypeScript)

- `Services/` is a pnpm workspace managed by [Vite+](https://viteplus.dev/guide/). Install the `vp` CLI (`brew install vite-plus`), then run `cd Services && vp install`.
- Node is pinned in `Services/.node-version`, and pnpm in `Services/package.json`.
- Dependency versions live only in the catalog in `Services/pnpm-workspace.yaml`. Packages refer to them as `catalog:`. Add dependencies with `vp add <pkg>@catalog:` after adding them to the catalog, and never install `@latest` (even where the `effect-ts` skill's setup steps say to).
- Check and test:
  - `vp check`: format, lint and type check.
  - `vp run -r test`: every package's tests.
  - In a package, e.g. `Services/api`: `vp test`.
- Lint and format settings live only in the root `Services/vite.config.ts`. Vite+ doesn't apply per-package lint or format configs.
- Vite+'s own docs ship in `Services/node_modules/vite-plus/docs`.

### API contract

- `Services/api/openapi.json` is the API's OpenAPI spec, generated from the HttpApi definition by `Services/api/scripts/openapi.ts` and served at `/v1/openapi.json`. Generated clients (the Swift `LilAPI` module) are built from the committed file.
- The Swift client is generated from that file into `LilPackage/Sources/LilAPIGenerated/Generated` by `scripts/generate-api-client`, which runs Apple's swift-openapi-generator pinned in `Tools/Package.swift`. Don't edit generated files.
- `scripts/format` regenerates both the spec and the client, in that order, and `scripts/format --lint` fails if either is stale. Commit them with any API change.
- **Compatibility:** installed apps keep running old clients.
  - Adding response fields is safe, because the spec allows additional properties.
  - Adding a case to a response enum, or removing or renaming anything, breaks them. Add a new field or a new endpoint instead.
  - `scripts/format --lint` fails if the spec is stale, or if the client's stamp doesn't match the spec, generator pin and config. The pre-commit hook also regenerates the client into a temporary directory and compares it (`scripts/generate-api-client --check`), which catches hand edits too.
- Apps use the client through `@Dependency(\.api)` (from `LilAPI`). Tests get a client that fails every request and reports an issue; answer requests with `Client.mock { request, body in … }`. `LIL_API_URL` in a scheme's environment points an app at another deployment, such as a PR preview.

### Deploying the API

- The API is an Alchemy stack in `Services/api/alchemy.run.ts`. The same stack deploys the website, `Services/site/public` (static files, such as the privacy policy), to `lil.tech` in prod, `staging.lil.tech` in staging, and workers.dev elsewhere. Its state lives in Cloudflare (an `alchemy-state-store` Worker in account 851), so every machine and CI share it.
- Run Alchemy from `Services/api` (`npx alchemy …`), where it's installed. From anywhere else, `npx` fetches a separate copy that can't find its peer dependencies.
- **Credentials:** once per machine, from `Services/api`, run `ALCHEMY_TUI=1 DO_NOT_TRACK=1 npx alchemy profile edit --add Cloudflare`. Choose OAuth, then **Basic Scopes**, then sign in with a Cloudflare user that's a member of account **851**, and pick that account. Credentials are saved in `~/.alchemy/profiles.json`. Alchemy hides its interactive prompts when it detects a coding agent, and `ALCHEMY_TUI=1` shows them again. Check credentials with `npx alchemy profile show`. The bare `npx alchemy profile` dashboard crashes in this beta, because `react` isn't installed.
- **Telemetry:** Alchemy reports usage to `otel.alchemy.run` unless `DO_NOT_TRACK=1` is set. Set it in your shell.
- **CI** (`.github/workflows/services.yml`) deploys changes to `Services/`. Its checks run in the pre-commit hook instead.
  - Pull requests are deployed to a preview stage, `pr-<number>`, on workers.dev. A PR comment links the preview.
  - Closing a PR destroys its preview.
  - To try a preview as a signed-in user, `POST /v1/auth/dev` (optionally with `{"displayName": "…"}`) creates a synthetic user and returns tokens. The route only exists in the `preview` environment (PR previews, and personal stages from `vp run deploy`, named `live_<user>`) and the `local` one (`alchemy dev`, `dev_<user>`). Each stage allows at most 1,000 users.
  - Merging to `main` deploys staging, then prod, and `scripts/check-deploy` waits until each serves the new commit.
  - CI authenticates with the `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repo secrets (token "lil.tech CI (Alchemy deploys)": account 851, zone `lil.tech`).
  - Previews run PR code with that deploy token, and Cloudflare can't limit `Workers Scripts:Edit` to particular Workers. Only branches pushed to this repo get previews (fork PRs get no secrets), so only give push access to people you'd trust with prod.
- **Deploying by hand** (from `Services/api`), rarely needed since CI deploys `main`:
  - `vp run deploy:staging` deploys to `api.staging.lil.tech`.
  - `vp run deploy:prod` deploys to `api.lil.tech`.
  - `vp run deploy` deploys your personal stage, on workers.dev only.
  - `node scripts/notifications.ts` applies the account's billing and usage notification policies. They're account-wide, so no stage deploys them. See DECISIONS.md for credentials.
  - Each script sets `LIL_ENVIRONMENT` and `LIL_VERSION` (the git SHA, with `-dirty` for uncommitted changes), which the Worker reads at deploy time. Deploy prod from a clean tree.
- A Worker's props Effect runs at deploy **and** inside the running Worker, where Alchemy services like `Stage` don't exist. Read them with `Effect.serviceOption`.
- **Alchemy is in beta and pinned exactly** (`alchemy` in the catalog). Before writing Alchemy code, look resources and APIs up in [alchemy.run/llms.txt](https://alchemy.run/llms.txt) (and `llms-full.txt`). If they disagree with the installed types in `Services/api/node_modules/alchemy`, the installed types win. Don't install third-party Alchemy skills.
- Workers with stage-dependent props (e.g. a domain per stage) use the class form, `Cloudflare.Worker<Self>()(id, propsEffect, impl)`. The plain `Cloudflare.Worker(id, props, impl)` form only accepts plain props.
- Alchemy's Effect Worker entry imports the module's **default** export, so Worker modules `export default class … extends Cloudflare.Worker<…>()(…)`.
- An `HttpApiBuilder` layer in a Worker gets its platform services from Alchemy's `Http.Platform` (`alchemy/Http`), which includes the no-op `FileSystem` Workers need.

### Learning more about Effect

This repository uses the Effect TypeScript library. The `effect-ts` skill (`.claude/skills/effect-ts`) sets this up.

Before writing any Effect code, first read `Services/node_modules/effect/AGENTS.md` **completely**, and follow the links in the file when required.

If you need to learn more about particular Effect APIs and concepts that the guide doesn't cover, search through the source code in `Services/node_modules/effect/src`.

## Previews

All visual validation goes through SwiftUI previews rendered with `RenderPreview`, not by running the app.

- Every feature has a preview for each state of its state machine: loaded, empty, loading, failed, pending, and edge-case content.
- A UI change comes with previews for each state it affects. Render them, check the snapshots, and attach them to both the PR and the Linear ticket (as a comment).
- `scripts/contact-sheet <out.png> <columns> <images…>` combines snapshots into one labeled image for the ticket.

## Privacy: user data

This repo is public. lil messages reads `~/Library/Messages/chat.db`, and dev machines with Full Disk Access can read the real file. lil health reads Apple Health on a developer's iPhone and stores it on our servers.

- **Never** commit `chat.db`, copies of it, or anything extracted from it.
- Reading the real `chat.db` locally to debug or explore is fine. Just never let its contents end up in commits, PRs, tickets, or other public places.
- Test fixtures and previews use synthetic data only, e.g. built from hand-written SQL.
- Before committing, check that no `.db` files or real message content are staged.
- **Health data** follows the same rules. Never commit, paste or attach real Health data (exports, samples, screenshots of real values, server rows), and never copy it into staging or preview environments.
- Testing lil health on your own iPhone is fine. Device builds talk to prod, so your real data stays in your own prod account. Simulator builds talk to staging or a PR preview, which only ever get synthetic data. Use synthetic data in tests, previews and tickets.
