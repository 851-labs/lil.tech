# Sync

How lil apps keep a local copy of a user's data in sync with `api.lil.tech`. The protocol is generic: lil health uses it first, and lil mail and lil calendar will reuse it. See `docs/DECISIONS.md` for why apps are local-first.

## Terms

- **Store:** one user's data on the server, in a SQLite-backed Durable Object addressed by `idFromName("user:<userId>")`.
- **Entity:** a kind of record with its own table and schema, named in `snake_case` (e.g. `health_sample`, `health_workout`, `health_pin`).
- **Record:** one row of an entity, identified by a string `id` that's unique within the entity.
- **Change:** one entry in the store's change log, recording that a record was upserted or deleted.
- **Cursor:** the `seq` of the last change a client has applied.
- **Snapshot:** a copy of every record in a store as of a given `seq`, used to start a new device.
- **Epoch:** a number that changes when the store's data is rewritten without going through the change log. Clients on an older epoch start over from a snapshot.

## The change log

Every write to a store goes through `applyMutations`, which updates the entity table and appends to the `changes` table in one SQLite transaction.

| Field | Type | Meaning |
|---|---|---|
| `seq` | integer | Position in the log. Starts at 1, increases by exactly 1 per change, never reused. |
| `entity` | string | Entity name. |
| `id` | string | Record ID. |
| `op` | `"upsert"` \| `"delete"` | What happened to the record. |
| `row` | object | The full record after an upsert, encoded with the entity's schema. Absent for deletes. |
| `at` | integer | When the change was written, in Unix milliseconds. |

- **No gaps:** a Durable Object handles one request at a time and each write is a single transaction, so `seq` values are dense. Clients can rely on that to detect missed changes.
- **Full rows, not patches:** an upsert always carries the whole record. Applying the same change twice, or applying changes on top of a newer snapshot, gives the same result. This makes every step below safe to retry.
- **No-op upserts are dropped:** if an upsert's encoded row equals the stored row, nothing is written and no change is appended. Retried uploads don't grow the log.
- **Last write wins per record:** the server's order of arrival decides. There's no field-level merge.

## Wire format

- JSON, with `camelCase` field names. The server stores `snake_case` columns and maps between them in the entity's schema.
- Timestamps are integers in Unix milliseconds, and durations are in seconds. Record IDs are strings.
- Health records use the HealthKit UUID, lowercased, as their `id`. Records created by our apps use a prefixed, sortable ID (e.g. `pin_01J…`).
- Every response that carries changes is gzip-compressed.

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

  - `next` is the cursor to send on the next request: the `seq` of the last change returned, or `after` if none were.
  - `head` is the newest `seq` in the store, so clients can show progress.
  - `hasMore` is true when `next < head`.
- The client applies a page in **one local transaction**: every change in order, then the new cursor and epoch. If the transaction fails, the cursor doesn't move and the page is fetched again.
- Unknown entities and unknown fields are skipped, but the cursor still moves past them. See [Schema changes](#schema-changes) for how a client catches up once it understands them.

### Client loop

```
loop:
  page = GET /v1/sync/changes?after=cursor
  if page.epoch != local.epoch: bootstrap(); continue
  transaction { apply(page.changes); cursor = page.next }
  if !page.hasMore: wait for a live notice (or 60 s), then loop
```

## Bootstrapping a new device

Replaying the whole log is too slow for a store with millions of records, so new devices start from a snapshot.

```
GET /v1/sync/snapshot
```

- Returns the latest snapshot's manifest, with short-lived download URLs (about 15 minutes) for each part. A client whose URLs expire mid-download asks again.
- If the store has no snapshot yet, it answers `204`, and the client pulls from `after=0`.
- Manifest:

  ```json
  {
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
  ```

- **Format:** each part is gzip-compressed NDJSON, one record per line in the same encoding as a change's `row`. Parts hold at most 250,000 records, so a failed download only retries one part.
- **Why not a SQLite file:** the client's tables don't mirror the server's (each app keeps only what it renders, in its own layout). A Durable Object also can't hand out its database as a file. NDJSON streams straight into batched inserts.
- **Loading:** the client downloads and checks each part, then inserts it in batches, into a fresh local database or after clearing synced tables. When every part is loaded, it sets `cursor = manifest.seq` and `epoch = manifest.epoch` and resumes pulling.

### Writing snapshots

- An alarm in the store writes a new snapshot when at least 50,000 changes or 7 days have passed since the last one, if anything changed.
- The snapshot is tagged with `S`, the store's `head` when it started. It pages through each entity table and writes the parts to R2.
- Writes keep flowing while the snapshot is written, so some rows in it may be newer than `S`. That's safe: the client pulls everything after `S` next, and full-row upserts and deletes give the same result when applied again.
- The manifest is written last, and only then becomes the latest snapshot. Older snapshots are deleted 7 days later, so downloads in progress can finish.

### Compaction

- Changes are deleted when they're both covered by the latest snapshot (`seq <= S`) and older than 30 days. Clients that synced within the last 30 days never need to bootstrap again.
- The store remembers its **horizon**, the highest `seq` it has deleted. A pull with `after < horizon` answers `410 Gone` with `{ "reason": "compacted" }`, and the client bootstraps.

## Live updates

```
GET /v1/sync/live   (WebSocket)
```

- Authenticated with the access token in the `Authorization` header, like every other request.
- Lives on the user's store as a hibernatable WebSocket, so idle connections cost nothing.
- The server sends `{ "type": "head", "seq": <n> }` when the socket opens, and after each write that appended changes, at most every 250 ms.
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
- Each entity declares whether clients may write it. Most synced data, such as health samples, can only be written by the server; app state such as pins and settings can be written by clients.
- **Optimistic local writes:** the client writes to its local tables and queues the mutation. Pulled changes overwrite local rows, and queued mutations are reapplied on top until the client's cursor reaches their `seq`.
- **Health ingestion** is a specialized push for large volumes. The iPhone uploads batch files to `POST /v1/health/batches`, which go through R2 and a queue into `applyMutations`. The resulting changes are ordinary log entries.

## Schema changes

- **Entity schemas only grow:** new optional fields and new entities are fine. Renaming, removing or changing the type of a field isn't. That needs a new entity (e.g. `health_sample_v2`) and a migration.
- **Clients ignore what they don't know:** unknown fields are dropped and unknown entities are skipped. An older app keeps working against a newer server.
- **Catching up after an update:** each app has a `syncSchema` number, bumped when a release starts storing a new field or entity. A client whose local database was synced with a lower `syncSchema` bootstraps again from a snapshot. Snapshots carry every field, so the new data arrives without the server knowing anything about client versions.
- **Server-side migrations:** a migration that rewrites many rows doesn't append a change per row. It increments the store's **epoch** and writes a new snapshot. Clients see the new epoch on their next pull and bootstrap.

## Errors

| Status | Meaning | Client does |
|---|---|---|
| `401` | The access token expired or is invalid. | Refresh the token, then retry. If refreshing fails, sign out. |
| `410` | The cursor is older than the horizon. | Bootstrap from a snapshot. |
| `429` | Rate limited. | Wait for `Retry-After`, then retry. |
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
| Mutation ID memory | 7 days |
| Live notice rate | At most one every 250 ms per store |
| Store size | Below the 10 GB Durable Object cap, enforced by a per-user quota |
