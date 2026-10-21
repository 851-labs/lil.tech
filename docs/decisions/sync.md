# Sync

<!-- Part of docs/DECISIONS.md, the index of decisions (851-2791). -->

- **Local-first:** apps keep a local SQLite copy of the user's data and query only that. Derived values (e.g. daily totals) are computed locally.
- **Change log:** every write to a user's data appends to their change log, with a sequence number that increases per user and has no gaps. Clients pull changes after their cursor, bootstrap new devices from snapshots, and get live notices over a WebSocket.
- **Generic:** the protocol isn't specific to health, so lil mail and lil calendar can reuse it. It's specified in `docs/SYNC.md`.
