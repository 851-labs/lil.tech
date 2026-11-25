# AGENTS.md

lil.tech was wound down on 2026-11-25. lil health and lil messages are discontinued: their apps, Swift package, API, sync service and Pixelbook were deleted from this repo, and every deployed service was destroyed, with every account's synced data. The history before that day has the code.

What's left:

- **The site** (`Web/site`): lil.tech's static pages, which say the apps are discontinued, and its small Alchemy stack.
- **The `effect-ts` skill** (`.claude/skills/effect-ts`, pinned in `skills-lock.json`).

**The next version of lil.tech will be built on [GPUI](https://www.gpui.rs).** Nothing of it is here yet. When it starts, this file gets its decisions and workflow.

## Workflow

- One focused change per PR, branched off `main`.
- `vp check` must pass before committing. `scripts/` and the pre-commit hook are gone, so nothing runs it for you locally: CI's `check` job does, on every PR.
- **GitHub Actions has two workflows:** `.github/workflows/pr.yml` for a pull request, and `main.yml` after a merge. Each starts with a `changes` job (`.github/actions/changes`) that decides whether the site is affected.
  - A PR gets `check` (`vp check`), a preview of the site when it touches it (torn down when the PR closes), then `pr-ok`, which passes when every other job passed or was skipped.
  - **`pr-ok` keeps its name:** the "Protect main" ruleset requires it by name, so renaming it means changing the ruleset too, which only Alexandru does. The ruleset doesn't require branches to be up to date with `main`.
  - A merge deploys the site to staging, then prod. Nothing in `main.yml` is cancelled: deploys queue in the order of the merges.
  - The repo is public. A fork's pull request runs no workflow until a maintainer approves it, and it runs its own copy of the workflows. Never approve a fork's run that changes `.github/`.

## TypeScript (Web/)

- The repo root is a pnpm workspace managed by [Vite+](https://viteplus.dev/guide/), with web projects in `Web/` (the site, `Web/site`). Install the `vp` CLI (`brew install vite-plus`), then run `vp install` at the root.
- Node is pinned in `.node-version`, and pnpm in `package.json`, both at the root.
- Dependency versions live only in the catalog in `pnpm-workspace.yaml`. Packages refer to them as `catalog:`. Add dependencies with `vp add <pkg>@catalog:` after adding them to the catalog, and never install `@latest` (even where the `effect-ts` skill's setup steps say to).
- `vp check`: format, lint and type check. There are no tests, and the site has no build: its pages are deployed as they are.
- Lint and format settings live only in the root `vite.config.ts`. Vite+ doesn't apply per-package lint or format configs. The formatter ignores everything outside the workspace (`.github/`, `.claude/`, the root's Markdown).
- Vite+'s own docs ship in `node_modules/vite-plus/docs`.

## The site

- `Web/site/public` is the whole site: `index.html`, the privacy policy (`privacy/`), the page for people who connected AI agents (`agents/`), `404.html` and `style.css`. Plain HTML, with no build step and no JavaScript.
- **The privacy policy** says what was deleted when the service shut down and what's left on people's devices. Keep it true: nothing in this repo collects anything, so a change that does (analytics, a form, an account) changes the policy first.
- `Web/site/alchemy.run.ts` is its Alchemy stack, `lil-site`: one `Site` Worker that serves `public` from Cloudflare's asset layer, with no Worker code. It's on `lil.tech` in prod, `staging.lil.tech` in staging, and workers.dev elsewhere. Its state lives in Cloudflare (an `alchemy-state-store` Worker in account 851, which other projects share), so every machine and CI share it.
- `public/version.txt` is the commit a deploy serves (`git describe`), written before each deploy by `pnpm run version` and ignored by git. CI's `check-deploy` action waits until a deploy serves it.

### Deploying

- Run Alchemy from `Web/site` (`npx alchemy …`), where it's installed. From anywhere else, `npx` fetches a separate copy that can't find its peer dependencies.
- **Credentials:** once per machine, from `Web/site`, run `ALCHEMY_TUI=1 DO_NOT_TRACK=1 npx alchemy profile edit --add Cloudflare`. Choose OAuth, then **Basic Scopes**, then sign in with a Cloudflare user that's a member of account **851**, and pick that account. Credentials are saved in `~/.alchemy`. Alchemy hides its interactive prompts when it detects a coding agent, and `ALCHEMY_TUI=1` shows them again. Check credentials with `npx alchemy profile show`.
- **Telemetry:** Alchemy reports usage to `otel.alchemy.run` unless `DO_NOT_TRACK=1` is set. Set it in your shell.
- **CI deploys:**
  - Pull requests that touch the site are deployed to a preview stage, `pr-<number>`, on workers.dev. A PR comment links the preview. Closing the PR destroys it; if the teardown fails, the job comments on the PR. Fix the cause and rerun the failed job.
  - Merging to `main` deploys staging, then prod, and waits until each serves the new commit. Running `main.yml` by hand deploys `main` again.
  - CI authenticates with the `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repo secrets (token "lil.tech CI (Alchemy deploys)": account 851, zone `lil.tech`).
  - Previews run PR code with that deploy token, and Cloudflare can't limit `Workers Scripts:Edit` to particular Workers. Only branches pushed to this repo get previews (fork PRs get no secrets), so only give push access to people you'd trust with prod.
- **Deploying by hand** (from `Web/site`), rarely needed since CI deploys `main`:
  - `pnpm run deploy:staging` deploys to `staging.lil.tech`, and `pnpm run deploy:prod` to `lil.tech`. Deploy prod from a clean tree.
  - `pnpm run deploy` deploys your personal stage (`live_<user>`), on workers.dev only. `npx alchemy destroy` removes it.
- **Alchemy is in beta and pinned exactly** (`alchemy` in the catalog). Before writing Alchemy code, look resources and APIs up in [alchemy.run/llms.txt](https://alchemy.run/llms.txt) (and `llms-full.txt`). If they disagree with the installed types in `Web/site/node_modules/alchemy`, the installed types win. Don't install third-party Alchemy skills.
- **Logical IDs must be unique in the stack,** across resource types. Alchemy doesn't reject a repeated ID: it returns the existing resource, so the second one is never created. Renaming a deployed resource's ID replaces it, unless you add `.pipe(Alchemy.renamedFrom("OldId"))`, which moves its state to the new ID.
- **A custom domain belongs to one Worker.** Alchemy refuses to attach a hostname another Worker holds, so moving `lil.tech` to another Worker or stack means detaching it from the old one first, and the site is down in between.
- The account's billing and usage notification policies (named `lil: …`, emailed to Alexandru) are account-wide and still in place. Nothing in this repo manages them any more.

### Learning more about Effect

This repository uses the Effect TypeScript library. The `effect-ts` skill (`.claude/skills/effect-ts`) sets this up.

Before writing any Effect code, first read `node_modules/effect/AGENTS.md` **completely**, and follow the links in the file when required.

If you need to learn more about particular Effect APIs and concepts that the guide doesn't cover, search through the source code in `node_modules/effect/src`.
