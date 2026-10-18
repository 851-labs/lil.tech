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
- **Full rows in the log:** every upsert in the log is served with the whole record. Each change keeps the record's key (its key fields' values and ID, store migration 17), and, while `logsRowCopies`, a copy of its row. An upsert logged without a copy is served with the record as it is now, read from its table by key; one whose record is gone or tombstoned is served as a delete. Applying the same change twice, or applying changes on top of a newer snapshot, gives the same result, and an older change showing newer values converges the same way. This makes every step below safe to retry. Code from before 851-2673 (#157) can't serve changes without a copy, so copies stopped (851-2676) only once it was live. Rolling back to it or later is safe; further back needs `logsRowCopies` turned on first, and then the changes logged without a copy compacted away, or a new epoch. A change logged without a copy, of an entity the running code doesn't know, ends the page before it, so clients wait rather than skip it.
- **No-op upserts are dropped:** if an upsert leaves the stored row unchanged, nothing is written and no change is appended. Retried uploads don't grow the log.
- **Last write wins per record:** the server's order of arrival decides. There's no field-level merge between concurrent writers.
- **Key fields:** an entity can be stored in the order of some of its fields (`Entity.key`), with `id` breaking ties. Its table's primary key is those fields, then `id` (`WITHOUT ROWID`), and there's no index on `id` alone. `health_sample` is stored by type and start date.
  - **Why:** HealthKit's UUIDs are random, so an index on them puts each new sample on a random page. In a Durable Object that cost about 150 µs of CPU per item, more than everything else applying it did. A backfill sends one type at a time in time order, so in key order a batch is written next to itself: about 80 µs per item end to end on the store (851-2651), and about 8× fewer pages written per transaction (measured locally).
  - **Upserts** find the record by its key fields and ID, so they must include the key fields, which never change once a record exists. HealthKit never changes a sample's type or start date. An upsert with the same ID and other key fields would be a second record.
  - **Deletes** carry only the ID, so they can't find the row. A delete leaves a tombstone (`src/store/Tombstones.ts`) and is in the log at once, so clients delete the record straight away. Its first delete is logged whether or not the record exists, and later ones aren't. An upsert after a delete removes the tombstone and brings the record back as a new one, needing every field again.
  - **Sweeping:** once the oldest tombstone is a day old, the store's alarm passes over each such table in key order, 50,000 rows a step and 2 seconds apart, removing tombstoned rows. As it finishes a table, it drops that table's tombstones from before the pass started. A pass reads every row, so it runs at most about daily, and like snapshots it waits while the store is taking in uploads. Until a record's row is gone, reads (snapshots) leave it out, and it still takes space: a store past its hard limit frees room from deleted samples only at the next pass.
  - **The key fields' values must never change for a record.** The iPhone rounds dates to the nearest millisecond (`HealthEncoder.milliseconds`, pinned by a test). Changing that would store re-uploaded samples twice.

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
- The Mac asks for 5,000 at a time, and downloads the next page while it writes one. A catch-up then runs at about the speed of decoding pages: about 7,600 changes a second for health samples in a Release build (851-2649).
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
- **Format:** each part is gzip-compressed NDJSON, one record per line in the same encoding as a change's `row`. Parts hold at most 25,000 records, so a failed download only retries one part.
- **Why not a SQLite file:** the client's tables don't mirror the server's (each app keeps only what it renders, in its own layout). A Durable Object also can't hand out its database as a file. NDJSON streams straight into batched inserts.
- **Loading:**
  1. Download and check each part (`sha256`), four at a time. Parts whose URLs expire together share one refresh.
  2. Clear the synced tables (or start a fresh local database) and insert every part in batches.
  3. Set `cursor = snapshot.seq` and `epoch = snapshot.epoch`, then resume pulling.
  4. Reapply the pending-mutation queue on top (see [Pushing changes](#pushing-changes)). Bootstrapping never discards unsent local writes.

### Writing snapshots

- An alarm in the store writes a new snapshot when enough has changed since the last one, or 7 days have passed, if anything changed. "Enough" is a quarter of the last snapshot's records, and at least 50,000 changes, so a big store isn't rewritten for a small share of changes. A new device pulls those from the log.
- **Not while ingesting:** a due snapshot waits until the store has taken in nothing for 2 minutes (no changes, and no batches received or applied, including ones that change nothing), and a snapshot in progress pauses the same way. During a bulk upload (millions of items), snapshotting every 50,000 changes rewrote everything stored so far again and again: the store's alarm ran about every 4 s, and every upload and batch apply queued behind it. To keep a store that never goes quiet from going without, the wait is capped at an hour: after the snapshot became due (and not before the previous one finished) for starting one, and after it started for one in progress.
- The snapshot is tagged with `S`, the store's `head` when it started. It pages through each entity table **in key order** (`WHERE id > :last ORDER BY id LIMIT :n`, or by the key fields then `id`), never by offset, and writes the parts to R2.
- Writes keep flowing while the snapshot is written, so some rows in it may be newer than `S`. That's safe: the client pulls everything after `S` next, and full-row upserts and deletes give the same result when applied again. Keyset paging makes sure no row that existed at `S` is skipped when earlier rows are deleted between pages.
- The manifest is written last, and only then becomes the latest snapshot.
- It's written one part per alarm, and the alarm is set again right away until it's done. A store does one thing at a time, so parts are small (about a second's work), and writing a part yields between pages so uploads and ingestion get in. A 250,000-record part on a ~500 MB store once took 22 s and got uploads refused as overloaded (503).
- Publishing a snapshot runs compaction (below) and deletes snapshots replaced more than 7 days ago, with their parts.

### Migrations and restores

A bulk server-side migration, or restoring a store from point-in-time recovery, changes data without appending changes. Either one:

1. Writes a snapshot of the resulting data, tagged with the next epoch.
2. Then, in one transaction, increments the store's epoch and publishes that snapshot as the latest.

Clients see the new epoch on their next pull and bootstrap from a snapshot that already contains the new data.

### Compaction

- Changes are deleted when they're both covered by the latest snapshot (`seq <= S`) and older than 30 days. Clients that synced within the last 30 days never need to bootstrap again.
- It deletes at most 50,000 changes per alarm, oldest first, and the rest in the alarms after, so it never holds the store for long.
- The store remembers its **horizon**, the highest `seq` it has deleted. A pull with `after < horizon` answers `410 Gone` with `{ "reason": "compacted" }`, and the client bootstraps.

## Live updates

```
GET /v1/sync/live   (WebSocket)
```

- Authenticated with the access token in the `Authorization` header, like every other request.
- Lives on the user's store as a hibernatable WebSocket, so idle connections cost nothing. The Worker checks the access token, then hands the upgrade to the store, together with when the token expires.
- The server sends `{ "type": "head", "seq": <n> }` when the socket opens and after writes that appended changes.
  - Notices are coalesced to at most one every 250 ms. The **latest** `head` is always sent at the end of the window, so the last write in a burst is never left unannounced.
- When `seq` is greater than its cursor, the client runs the pull loop. Notices carry no data; pulling is the only way data arrives.
- Keep-alive pings are answered automatically by the runtime, without waking the object.
- The server closes the socket with code `4001` when the access token is no longer good: it expired, or the account was deleted (851-2666). The client throws that token away, refreshes and reconnects with backoff.
  - **Deletion:** `DELETE /v1/me` tells the store to close its sockets once the account and its sessions are gone (`signOutDevices`), so the refresh fails and the client signs out and removes its local copy within seconds. While the deletion is still running, a refresh would succeed, so sockets stay open, and one that connects then waits without notices. Afterwards, new connections are closed with `4001` at once, since their tokens still verify for up to 15 minutes.
  - **Why `4001`:** apps from before 851-2666 reuse their token on `4001`, so they sign out once it expires (at most 15 minutes), as before. A new code would have made them retry forever.

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
  - **Applying:** a queue consumer streams the file, at most 64 MB decompressed and 1 MB per line, and applies the lines in chunks of up to 5,000 lines or 2 MB, one transaction each. Invalid lines are rejected with their line numbers and reasons, and the rest of the batch still applies. The file is deleted once the batch is applied.
    - **Throughput:** the store is a single thread, so it's the ceiling for one user. The consumer keeps it busy: it reads and checks the next chunk while one is being applied (in order, one at a time per batch), and a batch takes two store calls besides its chunks, one to start it and one to finish it. At most 4 batches are applied at once, across all users. A batch spends most of its time outside the store (reading, parsing, bookkeeping: about 1.5 s for 0.4 s of store time with 5,000 lines), so 2 left the store idle: 4 applied about 25% more (synthetic stage load test, 851-2675). Before applying got cheaper (851-2671, 851-2673), more only queued in front of a store, and with 3 a store was overloaded ("Durable Object is overloaded"), failing uploads with 503 while batches applied; at 4 since, none were. The limit is global for now (one user); per-user limits would need the queue sharded. Each applied batch logs its lines, time and items per second (`Health batch applied`).
  - **Blobs:** payloads too big for rows (ECG voltages, workout routes' locations) are uploaded first as blobs, and rows refer to them by SHA-256 (`src/health/HealthBlobs.ts`).
    - `PUT /v1/health/blobs/<sha256>` (`application/octet-stream`, at most 16 MB). The server checks the hash and stores the blob in R2 under `health-blobs/<user>/<sha256>`. Blobs are immutable: uploading one that's stored already changes nothing, so retries are safe. Like batches, uploads need consent and room in the quota.
    - The user's store records each blob's size (`health_blobs`), and the sizes count towards the storage quota.
    - `GET /v1/health/blobs/<sha256>` returns a download URL signed like snapshot parts' (15 minutes, `Range` supported), only for the user's own blobs. A token for one kind of file doesn't work for the other.
    - Deleting the account deletes the user's blobs.
    - **Sweep** (`src/store/BlobSweep.ts`): entities declare the fields that refer to blobs (`defineEntity`'s `blobs`). Once a day, from its alarm, the user's store marks blobs no record refers to (and unmarks ones referred to again). It deletes those unreferenced for 35 days, longer than point-in-time recovery's 30, so a restored store never refers to a deleted blob. Re-uploading a blob unmarks it, since a record is about to refer to it. The sweep also deletes R2 objects under the user's prefix that the store never recorded (an upload whose recording failed), once they're as old.
    - The Mac downloads a blob when a view needs it, through `BlobCache` (LilSync). It checks the hash (again on every hit), keeps blobs on disk in the app's own caches folder (1 GB, least recently used evicted first), shares one download between concurrent requests (cancelled once nobody's waiting), and asks for a fresh URL once if one expired. Signing out calls `removeAll()`.
    - The iPhone's backfill keeps a page's blobs with its batch files and uploads them first (`HealthBlobUploader`), so a row never arrives before its blob. The page is kept until both are accepted.
  - **Backfill:** the iPhone pages through each type's history with anchored queries (10,000 objects a page). It writes each page to batch files of at most 5,000 records and 15 MB uncompressed, saves the page as pending, and uploads them at once (up to four; a page of samples makes two, and types with small pages one). An upload mostly waits on the server, so a page's batches overlap, and each batch costs the server a fixed time to apply, so they aren't smaller; the anchor only moves once they're all accepted. The next page is read as soon as one is read, while it's written and uploaded; it's dropped if the upload fails, or if its page is given up on (its files went missing), so the loop reads from the saved anchor again.
    - A type's anchor is saved only after every batch of the page is accepted.
    - If the app is killed, the pending page is uploaded again under the same batch IDs, which is safe, and nothing is skipped.
    - A type with nothing to read keeps no anchor and is checked again on every run. HealthKit returns nothing both for no data and for denied access, and an anchor taken while access was denied would skip the history once it's granted.
    - Signing out resets the backfill.
    - **In the background:**
      - While signed in with an unfinished backfill, the app asks iOS for a `BGProcessingTask` (`tech.lil.health.sync`), before each foreground run starts.
      - Health can't be read while the phone is locked, which is when iOS usually runs that task, so it rarely gets far. The first upload mostly runs through a `BGContinuedProcessingTask` (iOS 26, `tech.lil.health.upload`), submitted when the user finishes onboarding or taps Continue / Try Again. It joins the running backfill and keeps it going after they leave the app, with its progress in the system's UI, until it's done or the phone locks. It reports records uploaded against the counted total once it's known (below), before then against a total estimated from the finished types with data, which moves with every page, so iOS doesn't take it as stalled. Coming back to the app after it was in the background (e.g. after the phone locked) picks the upload up again with a new task. Both background tasks share one guarded run: unlocked, with consent and signed in.
      - **Counting:** a full run also counts each unfinished type's records left, from its saved anchor, with large anchored queries that keep only counts (`HealthRecordCounter`). It's much faster than the upload. Once every type left is counted, the progress has `totalRecords`, and the status screen and the continued task show uploaded records against it. Counting is best-effort: a type that can't be counted leaves the total unknown, and the progress falls back to types.
      - The task continues the backfill and pauses when its time is up, keeping the pending page for next time.
      - A locked iPhone can't read Health, so the task waits for it to be unlocked instead of failing.
      - Uploads use the regular API client, not a background `URLSession`. iOS schedules background-session transfers started in the background at its own discretion, too late for HealthKit's and the task's deadlines. An upload cut off by suspension is just sent again.
  - **Incremental sync:** the iPhone registers an `HKObserverQuery` with background delivery (`.immediate`, which HealthKit limits per type) for every type, at every launch.
    - Observers are registered again after Health access is granted, to turn delivery on for types that weren't readable before.
    - A change runs the same page loop from the type's anchor, uploading additions and deletions.
    - Changes that arrive during a run join it, so a burst becomes one upload.
    - Changes wait until there's a backfill, so after signing out nothing goes up until the next account's backfill starts.
    - Every launch catches every type up from its anchor, so a change the app missed (killed, offline) still goes up.
    - A type that fails doesn't hold up the others. Its page is read again on the next run.
    - HealthKit is told the change is handled when the upload finishes, or after 25 seconds, whichever comes first.
  - **Statistics:** for cumulative types, the iPhone uploads HealthKit's own 30-minute sums (`HKStatisticsCollectionQuery` anchored at the Unix epoch, so buckets start on UTC half-hours), along with its `health_statistics_device` row (whether it's paired with an Apple Watch).
    - After a type's samples go up, its sums are uploaded again from the earliest time the changes affected to a day ahead, since samples can be logged ahead of time.
      - During a backfill, that's the earliest sample read.
      - After a change, it's the earliest added sample, or, when something was deleted, 7 days before the type's sums last went up. A deleted object has no dates.
    - Sums go up 90 days at a time, saving the progress after each, so a long history resumes where it stopped.
    - The most recent month of every recompute uploads empty buckets as zeros, so sums that are gone get overwritten. Older parts upload only buckets with data.
    - The device row goes up once per run.
    - A failed upload of sums is tried again on the next run. It doesn't count as a failure of the type's samples.
  - **Device-scoped records:** some entities belong to the iPhone that uploads them, such as `health_statistic` (30-minute sums from HealthKit) and `health_statistics_device`. The iPhone sends their IDs without a device (`<type>@<bucketStart>`, or `self` for the device's own record). The server stamps each one with the uploading device, taken from the access token: it sets the `device` field and stores the ID as `<device>/<id>` (or just `<device>` for `self`). Two iPhones' records never collide, and an iPhone never needs to know its device ID.
    - **Retirement:** when a device signs out for good (its last session ends), the server deletes its device row and retires it in the user's store. The store's alarm then deletes its device-scoped records, up to 2,000 per alarm and 5 seconds apart, as ordinary deletions in the change log, so clients delete them too. The device's own record (`self`, its statistics status) goes first, so clients stop treating it as a statistics source right away. A retired device's records are refused from then on: ingestion rejects their lines from a batch still in the queue, and the store refuses them as a backstop. The store retires the device before its row is deleted, so if retiring fails the row stays for a later cleanup. A daily job (`src/core/DeviceCleanup.ts`, a cron trigger at 04:23 UTC) retires devices that stopped without signing out: no live session, and not seen for a day. That covers a deleted app, a wiped phone, and refresh tokens that expired. It handles at most 200 a run, 10 at a time, so a run stays well under the Workers subrequest limit. A device whose store can't be reached keeps its row for the next run, and a deleted account's device counts as retired. Account deletion wipes everything anyway.
  - **Status:** `GET /v1/health/batches/<id>` returns `queued`, `applying`, `applied` (with counts and up to 100 rejected lines) or `failed`.
  - **Failures:** a delivery that fails (e.g. the store is briefly unavailable) is retried 5 times, 30 seconds apart. Then the batch is marked `failed` and its message goes to a dead-letter queue. A batch still `queued` after 24 hours, or `applying` after an hour, is reported `failed` and never applied later. The client uploads failed or rejected data again as a new batch.

## Schema changes

- **Entity schemas only grow:** new optional fields and new entities are fine. Renaming, removing or changing the type of a field isn't. That needs a new entity (e.g. `health_sample_v2`) and a migration.
- **Clients ignore what they don't know:** unknown fields are dropped and unknown entities are skipped. An older app keeps working against a newer server, and merge-on-upsert keeps it from erasing newer fields.
- **Catching up after an update:** each app has a `syncSchema` number (`LilSyncEngine(entities:syncSchema:)`, e.g. `HealthDatabase.syncSchema`), bumped when a release starts storing a new field or entity. `lilSyncState` records the number the local data was bootstrapped with (missing counts as 1), and which entities it holds. A client whose local database was synced with a lower `syncSchema`, or without an entity it now stores, bootstraps again from a snapshot. New entities need no bump; the number is for new fields of entities it already had. After a downgrade, the older release records its own number and entities, so coming back bootstraps again. Snapshots carry every field, so the new data arrives without the server knowing anything about client versions.
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
| `429` | Rate limited (`TooManyRequests`): too many requests from the user, or sign-ins or refreshes from the address. | Wait `retryAfterSeconds` (or `Retry-After`), then retry. A rate-limited refresh keeps the session. |
| `503` | A new epoch's snapshot is still being written (with `Retry-After`), or the user's store is briefly unavailable (e.g. during a deploy). | Wait for `Retry-After` if there is one, otherwise back off as for other `5xx`, then retry. |
| `507` | The user's storage quota is full (`StorageFull`). Deletes still apply. | Stop pushing and show the quota state. Pulls keep working. |
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
| Records per snapshot part | 25,000 (one part per alarm, about a second's work) |
| Changes compacted per alarm | 50,000 |
| Change log retention | Covered by a snapshot and older than 30 days |
| Replaced snapshot retention | 7 days |
| Mutation ID memory | 7 days |
| Live notice rate | At most one every 250 ms per store, always including the latest `head` |
| Store size | Below the 10 GB Durable Object cap, enforced by a per-user quota |
