# Sync throughput benchmark

How fast a user's whole Health database goes from the iPhone, through the server, to a new Mac, stage by stage (851-2650). Each stage should approach its own limit (HealthKit reads, the network, the store's SQLite writes, the Mac's downloads and inserts), and stages should overlap. The benchmark is a repeatable synthetic load to compare against those limits and catch regressions. Decisions it informs go in `docs/decisions/server.md`.

## Running it

```sh
scripts/bench-sync                     # 200,000 records, about 4 minutes
scripts/bench-sync --records 1000000   # a big run, about 7 minutes
```

`vp run bench` in `Services/api` runs the same script, with the same options. `--help` lists them.

- It deploys your personal stage (`live_<user>`, on workers.dev, as `vp run deploy` does) from the working tree, then runs against it. `--url <stage>` (or `LIL_BENCH_API_URL`) skips the deploy and runs against that stage instead. It refuses prod, by its host and by what `/v1/status` says.
- It needs the Alchemy login from AGENTS.md (for the deploy), Xcode (for the Mac's stage), and nothing else running that loads the Mac or the network.
- It signs in a new synthetic user with dev sign-in (`{"account": "bench-<time>"}`), gives it consent, and deletes it at the end (`DELETE /v1/me`, which deletes its store, snapshots and blobs), also after a failure or Ctrl-C. So runs don't add up towards a stage's 1,000 users. `--keep` keeps it.
- **Staging** has no dev sign-in. To run against it, set `LIL_BENCH_REFRESH_TOKEN` to a refresh token of a staging account whose data may grow (synthetic only, like everything on staging), with `--url https://api.staging.lil.tech`. That account is never deleted, and its earlier data makes the snapshot wait for enough changes (a quarter of its last snapshot).
- Other options: `--concurrency <n>` uploads at once (default 4, as many as the iPhone's backfill keeps), `--skip-mac`, `--seed <n>` to make the same data again, `--json <file>` to keep the results.
- Under 50,000 records it stops after applying: a store's first snapshot needs 50,000 changes (`snapshotPolicy.minChanges`).
- Running it locally (`alchemy dev`) would measure workerd on the Mac, with local stand-ins for the queue, R2 and the Durable Object's storage, none of which behave like Cloudflare's. A personal stage runs the same Workers, queue, Durable Objects and R2 as prod, so every stage is measured on the real thing.

## What each stage measures

- **Read:** not run. HealthKit reads were measured on the owner's iPhone in prod: 0.3 s per 2,000-item page. Real Health data must never go to staging or a preview, so the benchmark doesn't go through an iPhone; the table repeats that number for comparison.
- **Data:** `Services/api/scripts/synthetic-health.ts` makes batch files exactly as `HealthBatchWriter` does: gzip NDJSON of upserts in the push format with sorted keys, a type at a time in time order, 10,000-record pages cut into files of at most 5,000 records (and 15 MB), and each file's source revisions and devices once, as `health_provenance` records the rows refer to. The mix is roughly a Watch wearer's: heart rate (38%), active and resting energy, distance, steps, sleep and stand hours, the iPhone's 30-minute sums (`health_statistic`), and a few workouts. Values are made up; a test applies a run's files through the real ingestion and checks no line is rejected. Lines are about 450 bytes before compression, like real ones (372–490), but compress to about 32 bytes, which real data, with more varied values and metadata, wouldn't.
- **Upload:** `PUT /v1/health/batches/<id>` for every file, 4 at a time, from the first request to the last `202`. Per-batch latency (p50, p90) and retries (429, 5xx) are in the notes. It's what the iPhone's uploads cost the server, from a Mac on a fast connection: the iPhone's own network and `URLSession` aren't in it.
- **Apply:** from the first batch's `receivedAt` (server time) to the `at` of the change log's last change, found once `head` reaches the start plus every record and each new provenance (`GET /v1/sync/changes`). It's the whole ingest pipeline: the queue, the consumer and the store's transactions. Uploads finish well before (the notes say how long), so this is the server's rate, not the uploads'.
- **Snapshot:** a store writes a snapshot once it has been quiet for 2 minutes (`docs/SYNC.md`). From the snapshot's `createdAt` (when the store started it) to when `GET /v1/sync/snapshot` first returned it, polled every 0.5 s. The wait for quiet is policy, not throughput: it's in the notes, and left out of the wall clock's second figure.
- **Mac download, insert, bootstrap:** `SyncBootstrapBenchmark` (`LilPackage/Tests/HealthDatabaseTests`), built and run in Release, drives the Mac's real `LilSyncEngine.bootstrap()` with lil health's entities into a new database on disk, against the stage with the synthetic user's token. Download is from the start until the last part arrived (4 at a time, each checked against its SHA-256); insert is the rest: clearing the tables, decompressing and loading every record, 5,000 per transaction. The benchmark builds it before anything is timed. It checks the Mac ends up with every record.
- **Wall clock:** from the first upload until the Mac finished bootstrapping, and the same without the snapshot's wait for quiet.

## Physical limits

- **HealthKit:** 6,700 items/s on the owner's iPhone (prod, above). Every stage after it ran faster than that. Applying (6,100–8,200 items/s) came closest, so it's what would hold a first sync back once the iPhone reads faster or several devices upload.
- **Network:** the uploads move under 1 MB/s and the downloads up to about 10 MB/s, a small fraction of a gigabit connection, so neither is near the network's limit. Both are bound by round trips: an upload by the server's work per batch (two store calls, the R2 put, the queue send, 851-2667), a download by a few small parts at a time.
- **The store:** a user's store is one Durable Object, one thread. Applying cost about 80 µs of CPU per sample after 851-2651 (12,500 items/s), less since grouped upserts and a change log without row copies (851-2671, 851-2673). The best one user has applied is about 9,500 items/s (851-2652, step samples only). It's the stage furthest below the others.
- **The Mac:** SQLite on an SSD. A sample costs about 9 µs to upsert through a prepared statement (851-2649), so about 100,000 items/s for the writes alone.

## Results

**Prod**, during the owner's first upload (6.5M items), per 2,000-item page, before the snapshot's wait for quiet (measured for the ticket): 0.3 s read (6,700 items/s), 1.6 s upload (1,250 items/s; 11 ms of CPU, the rest waiting on the store), 4.4 s apply (450 items/s). The store's alarm ran 911 times an hour at 1.3 s each, re-snapshotting everything stored so far, which is what the quiet period stopped.

**2026-10-21**, personal stage (`live_tuftlord`) running `main` at 8176b88 (deployed as `d3fb94b-dirty`: the benchmark's commit, with only its own scripts and docs changed). Apple M1 Pro (10 cores, 16 GB), macOS 27, on gigabit Ethernet. 4 uploads at once. Items per second:

| Stage | 200,000 records (run 1) | 200,000 (run 2) | 1,000,000 |
| --- | ---: | ---: | ---: |
| Read (HealthKit, on device, not run) | 6,667 | 6,667 | 6,667 |
| Upload | 18,481 (10.8 s) | 22,938 (8.7 s) | 22,260 (44.9 s) |
| Apply | 7,439 (26.9 s) | 6,146 (32.5 s) | 8,209 (121.8 s) |
| Snapshot | 21,259 (9.4 s) | 18,730 (10.7 s) | 24,291 (41.2 s) |
| Mac download | 141,236 (1.4 s) | 112,209 (1.8 s) | 280,133 (3.6 s) |
| Mac insert | 27,475 (7.3 s) | 23,085 (8.7 s) | 15,538 (64.4 s) |
| Mac bootstrap | 23,001 (8.7 s) | 19,146 (10.4 s) | 14,721 (67.9 s) |
| Wall clock | 177 s (57 s without the quiet period) | 186 s (66 s) | 367 s (247 s) |

- Uploads finished 17–78 s before applying did: with 4 in flight, the queue is always full, so applying sets the pace (per batch p50 0.5–0.7 s, p90 about 1 s, no retries).
- Applying is 14–18 times prod's 450 items/s. Prod's store held millions of rows and was re-snapshotting every few seconds, so the two aren't the same load; a run with `--records 6500000` would come closer.
- The Mac's inserts slow down as its tables grow: 36 µs a record at 200,000, 64 µs at 1,000,000. That's the one stage that got slower with size.
- The snapshot's 2-minute wait for quiet is most of the wall clock at these sizes. It's policy rather than throughput: without it the store re-snapshots while ingesting, as in prod.
