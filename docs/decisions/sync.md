# Sync

<!-- Part of docs/DECISIONS.md, the index of decisions (851-2791). -->

- **Local-first:** apps keep a local SQLite copy of the user's data and query only that. Derived values (e.g. daily totals) are computed locally.
- **Change log:** every write to a user's data appends to their change log, with a sequence number that increases per user and has no gaps. Clients pull changes after their cursor, bootstrap new devices from snapshots, and get live notices over a WebSocket.
- **Generic:** the protocol isn't specific to health, so lil mail and lil calendar can reuse it. It's specified in `docs/SYNC.md`.
- **Loading snapshots** (851-2859): records go to a staging table without indexes, then into their table in one transaction, in primary key order, with the table's other indexes dropped and built again in that transaction. Upserting them in the server's order put random HealthKit IDs all over the primary key's index, and inserts slowed down as the database grew (36 µs a record at 200,000, 64 µs at 1,000,000). The cost: the Mac shows the new data all at once, at the end, rather than as it loads, and the last transaction holds the database's writer for a few seconds per million records (other writes wait for a bootstrap anyway).
