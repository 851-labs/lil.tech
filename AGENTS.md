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
- Don't bundle unrelated changes. If you find extra work, file a new ticket.

## Building

- Open `Lil.xcworkspace` in Xcode, not the individual `.xcodeproj`.
- From the command line:
  - Package tests: `cd LilPackage && swift test`
  - App: `xcodebuild -workspace Lil.xcworkspace -scheme LilMessages -destination 'platform=macOS' -skipMacroValidation build`
- `-skipMacroValidation` skips Xcode's one-time "trust this macro" prompt for package macros (TCA, CasePaths, etc.) in command-line builds.
- **Xcode macro trust.** In Xcode, package macros must be trusted once per version: click the macro error, then "Trust & Enable". After a dependency update, an error saying a macro "was changed since a previous approval" means the new version needs trusting again. Approvals live in `~/Library/org.swift.swiftpm/security/macros.json`, keyed by package, macro target and git revision. If you edit that file, remove stale entries for the same target and restart Xcode, because its build service caches the list.
- **Previews of SwiftUI `List`s.** Put a `#Preview` for a view whose `List` uses `ForEach` rows in a separate `*Previews.swift` file. Previewing a file instruments its functions, and with `ForEach` rows that trips an assertion in SwiftUI's macOS `List` (`TableViewListCore_Mac2`).
- **Xcode MCP.** `.mcp.json` registers Xcode's MCP server (`xcrun mcpbridge`), which provides tools like `RenderPreview`. Approve it when Claude Code first asks. It talks to the running Xcode, so keep Xcode open with `Lil.xcworkspace`, and allow external agents in Xcode › Settings › Intelligence. `xcrun` uses whichever Xcode `xcode-select` points at.
- **Preview snapshots.** Xcode's `RenderPreview` (MCP) snapshots a preview's first frame, before `.task` runs. Give previews their data in the initial state, using `makePreviewChatDatabase()` from `MessagesDatabase`, so snapshots show real content. That demo dataset is for previews only; tests seed their own data. For a state that a view's `.task` would immediately replace (empty, checking access), build the store with `EmptyReducer()`.

## Services (TypeScript)

- `Services/` is a pnpm workspace managed by [Vite+](https://viteplus.dev/guide/). Install the `vp` CLI (`brew install vite-plus`), then run `cd Services && vp install`.
- Node is pinned in `Services/.node-version`, and pnpm in `Services/package.json`. Dependency versions live in the catalog in `Services/pnpm-workspace.yaml`.
- Check and test:
  - `vp check`: format, lint and type check.
  - `vp run -r test`: every package's tests.
  - In a package, e.g. `Services/api`: `vp test`.
- Lint and format settings live only in the root `Services/vite.config.ts`. Vite+ doesn't apply per-package lint or format configs.
- Vite+'s own docs ship in `Services/node_modules/vite-plus/docs`.

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
