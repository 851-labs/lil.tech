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
- Run `scripts/format` before committing. `scripts/format --lint` must pass.
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

## Previews

All visual validation goes through SwiftUI previews rendered with `RenderPreview`, not by running the app.

- Every feature has a preview for each state of its state machine: loaded, empty, loading, failed, pending, and edge-case content.
- A UI change comes with previews for each state it affects. Render them, check the snapshots, and attach them to both the PR and the Linear ticket (as a comment).
- `scripts/contact-sheet <out.png> <columns> <images…>` combines snapshots into one labeled image for the ticket.

## Privacy: Messages data

This repo is public. lil messages reads `~/Library/Messages/chat.db`, and dev machines with Full Disk Access can read the real file.

- **Never** commit `chat.db`, copies of it, or anything extracted from it.
- Reading the real `chat.db` locally to debug or explore is fine. Just never let its contents end up in commits, PRs, tickets, or other public places.
- Test fixtures and previews use synthetic data only, e.g. built from hand-written SQL.
- Before committing, check that no `.db` files or real message content are staged.
