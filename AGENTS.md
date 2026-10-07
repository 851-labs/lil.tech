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
- Don't bundle unrelated changes. If you find extra work, file a new ticket.

## Privacy: Messages data

This repo is public. Lil Messages reads `~/Library/Messages/chat.db`, and dev machines with Full Disk Access can read the real file.

- **Never** commit `chat.db`, copies of it, or anything extracted from it.
- Reading the real `chat.db` locally to debug or explore is fine. Just never let its contents end up in commits, PRs, tickets, or other public places.
- Test fixtures and previews use synthetic data only, e.g. built from hand-written SQL.
- Before committing, check that no `.db` files or real message content are staged.
