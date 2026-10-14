# Sync

How lil apps keep a local copy of a user's data in sync with `api.lil.tech`. The protocol is generic: lil health uses it first, and lil mail and lil calendar will reuse it. See `docs/DECISIONS.md` for why apps are local-first.

## Terms

- **Store:** one user's data on the server, in a SQLite-backed Durable Object addressed by `idFromName("user:<userId>")`.
- **Entity:** a kind of record with its own table and schema, named in `snake_case` (e.g. `health_sample`, `health_workout`, `health_pin`).
- **Record:** one row of an entity, identified by a string `id` that's unique within the entity.
- **Change:** one entry in the store's change log, recording that a record was upserted or deleted.
- **Cursor:** the `seq` of the last change a client has applied.
- **Snapshot:** a copy of every record in a store as of a given `seq`, used to start a new device.
- **Epoch:** a number that changes when the store's data changes without going through the change log, such as a bulk migration or a restore from backup. Clients on an older epoch start over from a snapshot.

## The change log

Every write to a store goes through `applyMutations`, which updates the entity table and appends to the `changes` table in one SQLite transaction.

| Field | Type | Meaning |
|---|---|---|
| `seq` | integer | Position in the log. Starts at 1, increases by exactly 1 per change, and is never reused within an epoch. |
| `entity` | string | Entity name. |
| `id` | string | Record ID. |
| `op` | `"upsert"` \| `"delete"` | What happened to the record. |
| `row` | object | The full record after an upsert, encoded with the entity's schema. Absent for deletes. |
| `at` | integer | When the change was written, in Unix milliseconds. |

- **No gaps:** a Durable Object interleaves requests at every `await`, so `applyMutations` must read `head`, write the entity rows and insert the changes inside one synchronous transaction (`transactionSync`) with no `await` inside it. Then `seq` values are dense, and clients can rely on that to detect missed changes.
- **Full rows in the log:** every upsert in the log carries the whole record. Applying the same change twice, or applying changes on top of a newer snapshot, gives the same result. This makes every step below safe to retry.
- **No-op upserts are dropped:** if an upsert leaves the stored row unchanged, nothing is written and no change is appended. Retried uploads don't grow the log.
- **Last write wins per record:** the server's order of arrival decides. There's no field-level merge between concurrent writers.

## Wire format

- JSON, with `camelCase` field names. The server stores `snake_case` columns and maps between them in the entity's schema.
- Timestamps are integers in Unix milliseconds, and durations are in seconds. Record IDs are strings.
- Health records use the HealthKit UUID, lowercased, as their `id`. Records created by our apps use a prefixed, sortable ID (e.g. `pin_01J…`).
- Every response that carries changes is compressed. Cloudflare's edge compresses JSON responses with gzip or brotli, whichever the client accepts, so the Worker sends plain JSON.

## Pulling changes

```
GET /v1/sync/changes?after=<seq>&limit=<n>
```

- `after` is the client's cursor (0 for a client with nothing). `limit` defaults to 1000, and the maximum is 5000.
- The response:

  ```json
  {
    "epoch": 3,
    "changes": [
      { "seq": 1042, "entity": "health_sample", "id": "…", "op": "upsert", "row": { … }, "at": 1760400000000 }
    ],
    "next": 1042,
    "head": 98113,
    "hasMore": true
  }
  ```

  - `op` is `upsert` or `delete` today. Clients skip ops they don't know (like unknown entities), so new ones can be added.
  - `next` is the cursor to send on the next request: the `seq` of the last change returned, or `after` if none were.
  - `head` is the newest `seq` in the store, so clients can show progress.
  - `hasMore` is true when `next < head`.
- The client applies a page in **one local transaction**: every change in order, then the new cursor and epoch. If the transaction fails, the cursor doesn't move and the page is fetched again.
- Unknown entities and unknown fields are skipped, but the cursor still moves past them. See [Schema changes](#schema-changes) for how a client catches up once it understands them.

### Client loop

```
loop:
  page = GET /v1/sync/changes?after=cursor
  if local.epoch == null and cursor == 0: local.epoch = page.epoch   # brand-new client, nothing to replace
  if page.epoch != local.epoch or cursor > page.head: bootstrap(); continue
  transaction { apply(page.changes); cursor = page.next }
  if !page.hasMore: wait for a live notice (or 60 s), then loop
```

A cursor ahead of `head` means the store went back in time (e.g. a restore that didn't bump the epoch), so the client starts over rather than waiting for `seq` values it already has.

## Bootstrapping a new device

Replaying the whole log is too slow for a store with millions of records, so new devices start from a snapshot.

```
GET /v1/sync/snapshot
GET /v1/sync/snapshots/<id>
```

- `GET /v1/sync/snapshot` returns the store's current epoch and the latest snapshot whose epoch matches it:

  ```json
  {
    "epoch": 3,
    "snapshot": {
      "id": "snp_01J…",
      "seq": 95000,
      "epoch": 3,
      "createdAt": 1760400000000,
      "entities": [
        {
          "entity": "health_sample",
          "parts": [{ "url": "https://…", "records": 250000, "bytes": 18734211, "sha256": "…" }]
        }
      ]
    }
  }
  ```

  - `snapshot` is absent when the store has none yet (a new user). The client sets `epoch`, keeps `cursor = 0` and pulls the whole log.
  - The endpoint never returns a snapshot from an older epoch. While a new epoch's snapshot is still being written, it answers `503` with `Retry-After`.
- Part URLs are short-lived (about 15 minutes) and need no `Authorization` header, so background downloads work. They point at `/v1/sync/parts?token=…`, whose token is signed by the server for one part of the requesting user's snapshot. When they expire mid-download, the client asks for **the same snapshot** with `GET /v1/sync/snapshots/<id>`, which re-signs the URLs. A snapshot stays available for 7 days after a newer one replaces it. If it's gone (`410`), the client starts the bootstrap over, so it never mixes parts from two snapshots.
- **Format:** each part is gzip-compressed NDJSON, one record per line in the same encoding as a change's `row`. Parts hold at most 250,000 records, so a failed download only retries one part.
- **Why not a SQLite file:** the client's tables don't mirror the server's (each app keeps only what it renders, in its own layout). A Durable Object also can't hand out its database as a file. NDJSON streams straight into batched inserts.
- **Loading:**
  1. Download and check each part (`sha256`).
  2. Clear the synced tables (or start a fresh local database) and insert every part in batches.
  3. Set `cursor = snapshot.seq` and `epoch = snapshot.epoch`, then resume pulling.
  4. Reapply the pending-mutation queue on top (see [Pushing changes](#pushing-changes)). Bootstrapping never discards unsent local writes.

### Writing snapshots

- An alarm in the store writes a new snapshot when at least 50,000 changes or 7 days have passed since the last one, if anything changed.
- The snapshot is tagged with `S`, the store's `head` when it started. It pages through each entity table **by `id`** (`WHERE id > :last ORDER BY id LIMIT :n`), never by offset, and writes the parts to R2.
- Writes keep flowing while the snapshot is written, so some rows in it may be newer than `S`. That's safe: the client pulls everything after `S` next, and full-row upserts and deletes give the same result when applied again. Keyset paging makes sure no row that existed at `S` is skipped when earlier rows are deleted between pages.
- The manifest is written last, and only then becomes the latest snapshot.
- It's written one part per alarm, and the alarm is set again right away until it's done. No single invocation runs long, and requests are served in between.
- Publishing a snapshot runs compaction (below) and deletes snapshots replaced more than 7 days ago, with their parts.

### Migrations and restores

A bulk server-side migration, or restoring a store from point-in-time recovery, changes data without appending changes. Either one:

1. Writes a snapshot of the resulting data, tagged with the next epoch.
2. Then, in one transaction, increments the store's epoch and publishes that snapshot as the latest.

Clients see the new epoch on their next pull and bootstrap from a snapshot that already contains the new data.

### Compaction

- Changes are deleted when they're both covered by the latest snapshot (`seq <= S`) and older than 30 days. Clients that synced within the last 30 days never need to bootstrap again.
- The store remembers its **horizon**, the highest `seq` it has deleted. A pull with `after < horizon` answers `410 Gone` with `{ "reason": "compacted" }`, and the client bootstraps.

## Live updates

```
GET /v1/sync/live   (WebSocket)
```

- Authenticated with the access token in the `Authorization` header, like every other request.
- Lives on the user's store as a hibernatable WebSocket, so idle connections cost nothing.
- The server sends `{ "type": "head", "seq": <n> }` when the socket opens and after writes that appended changes.
  - Notices are coalesced to at most one every 250 ms. The **latest** `head` is always sent at the end of the window, so the last write in a burst is never left unannounced.
- When `seq` is greater than its cursor, the client runs the pull loop. Notices carry no data; pulling is the only way data arrives.
- Keep-alive pings are answered automatically by the runtime, without waking the object.
- The server closes the socket with code `4001` when the access token expires. The client refreshes its token and reconnects with backoff.

## Pushing changes

```
POST /v1/sync/mutations
```

```json
{
  "mutationId": "c7a1…",
  "mutations": [
    { "entity": "health_pin", "op": "upsert", "id": "pin_01J…", "row": { … } }
  ]
}
```

- `mutationId` is a UUID the client generates. The store remembers it for 7 days and answers a repeat with the original result, so retries are safe.
- Every mutation in a request is applied in one transaction, or none are. The response is `{ "seq": <n> }`, the `seq` of the last change it produced (or `head` if nothing changed).
- **Client upserts merge:** fields missing from `row` keep their stored values, and `null` clears a field. An older app that doesn't know a field can't erase it. The change appended to the log still carries the full merged row.
- Each entity declares whether clients may write it. Most synced data, such as health samples, can only be written by the server; app state such as pins and settings can be written by clients.
- **Optimistic local writes:**
  - The client writes to its local tables and adds the mutation to a pending queue, together with the record's previous local state.
  - Pulled changes overwrite local rows, and pending mutations are reapplied on top until the client's cursor reaches the `seq` returned for them.
  - The queue lives outside the synced tables, so it survives a bootstrap.
  - If the server rejects a mutation permanently (see [Errors](#errors)), the client drops it from the queue and restores the record's previous state.
- **Health ingestion** is a specialized push for large volumes, which the iPhone can send from a background `URLSession`. The resulting changes are ordinary log entries.
  - **Upload:** `PUT /v1/health/batches/<id>` with a client-generated lowercase UUID. The body is a gzip-compressed NDJSON file (`application/gzip`, at most 16 MB), one mutation per line in the push format. Only health entities are allowed, and rows are full records.
  - **Queueing:** the API stores the file in R2, queues it, and answers `202` with the batch's status. Uploading the same ID again only returns its status, so retries are safe.
  - **Applying:** a queue consumer streams the file, at most 64 MB decompressed and 1 MB per line, and applies the lines in chunks of 500, one transaction each. Invalid lines are rejected with their line numbers and reasons, and the rest of the batch still applies. The file is deleted once the batch is applied.
  - **Status:** `GET /v1/health/batches/<id>` returns `queued`, `applying`, `applied` (with counts and up to 100 rejected lines) or `failed`.
  - **Failures:** a delivery that fails (e.g. the store is briefly unavailable) is retried 5 times, 30 seconds apart. Then the batch is marked `failed` and its message goes to a dead-letter queue. A batch still `queued` after 24 hours, or `applying` after an hour, is reported `failed` and never applied later. The client uploads failed or rejected data again as a new batch.

## Schema changes

- **Entity schemas only grow:** new optional fields and new entities are fine. Renaming, removing or changing the type of a field isn't. That needs a new entity (e.g. `health_sample_v2`) and a migration.
- **Clients ignore what they don't know:** unknown fields are dropped and unknown entities are skipped. An older app keeps working against a newer server, and merge-on-upsert keeps it from erasing newer fields.
- **Catching up after an update:** each app has a `syncSchema` number, bumped when a release starts storing a new field or entity. A client whose local database was synced with a lower `syncSchema` bootstraps again from a snapshot. Snapshots carry every field, so the new data arrives without the server knowing anything about client versions.
- **Server-side migrations** go through a new epoch, as described in [Migrations and restores](#migrations-and-restores).
- **Rolling the server back** past an entity schema change also needs a new epoch. The older code writes log rows without the newer fields, so clients would apply incomplete rows.

## Errors

| Status | Meaning | Client does |
|---|---|---|
| `400` | A mutation or request is invalid. The body lists each rejected mutation and why. | Permanent: drop the mutation and restore the record's previous local state. |
| `401` | The access token expired or is invalid. | Refresh the token, then retry. If refreshing fails, sign out. |
| `403` | The entity can't be written by clients. | Permanent, like `400`. |
| `410` | The cursor is older than the horizon, or the requested snapshot was deleted. | Bootstrap from a snapshot. |
| `413` | Too many mutations or too large a request. | Split the request (a client bug if it happens). |
| `429` | Rate limited. | Wait for `Retry-After`, then retry. |
| `503` | A new epoch's snapshot is still being written (with `Retry-After`), or the user's store is briefly unavailable (e.g. during a deploy). | Wait for `Retry-After` if there is one, otherwise back off as for other `5xx`, then retry. |
| `507` | The user's storage quota is full. | Stop pushing and show the quota state. Pulls keep working. |
| `5xx`, network errors | Transient failure. | Retry with exponential backoff and jitter, from 1 s up to 5 minutes. |

An epoch mismatch isn't an error status: pulls always return the store's `epoch`, and the client compares it with its own.

## Security

- The user comes only from the session. The API derives the store from the session's user ID and never accepts a user or store ID from the client.
- Snapshot and blob download URLs are signed, short-lived, and scoped to the requesting user's objects.
- Deleting an account deletes the store, its snapshots and its blobs. A client that gets `401` and can't refresh signs out and wipes its local data.

## Limits

| Limit | Value |
|---|---|
| Changes per pull page | 1,000 by default, 5,000 maximum |
| Mutations per push | 500 |
| Records per snapshot part | 250,000 |
| Change log retention | Covered by a snapshot and older than 30 days |
| Replaced snapshot retention | 7 days |
| Mutation ID memory | 7 days |
| Live notice rate | At most one every 250 ms per store, always including the latest `head` |
| Store size | Below the 10 GB Durable Object cap, enforced by a per-user quota |
