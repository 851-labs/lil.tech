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
- **Staging** has no dev sign-in. To run against it, set `LIL_BENCH_REFRESH_TOKEN` to a refresh token of a staging account whose data may grow (synthetic only, like everything on staging), with `--url https://api.staging.lil.tech`. That account is never deleted. Its next snapshot needs a quarter of its last one's records to have changed, so a run too small for that stops after applying. A refresh token works once: the run uses it up and prints the new one for the next run.
- Other options: `--concurrency <n>` uploads at once (default 4, as many as the iPhone's backfill keeps), `--skip-mac`, `--seed <n>` to make the same data again, `--json <file>` to keep the results.

The Mac's inserts alone run without a stage (851-2859), in a minute or so:

```sh
cd LilPackage
LIL_BENCH_LOAD_RECORDS=1000000 swift test -c release --filter SyncLoadBenchmark
```

`SyncLoadBenchmark` (`LilPackage/Tests/Health/HealthDatabaseTests`) serves `LilSyncEngine.bootstrap()` a synthetic snapshot from memory, shaped like a stage's (nine in ten records are samples, in their key order with random HealthKit UUIDs, the rest statistics), so it times only decoding and inserting. It prints the time a record, and SQLite's pages read from disk and written a record, which don't depend on how busy the Mac is.
- Under 50,000 records it stops after applying: a store's first snapshot needs 50,000 changes (`snapshotPolicy.minChanges`).
- Running it locally (`alchemy dev`) would measure workerd on the Mac, with local stand-ins for the queue, R2 and the Durable Object's storage, none of which behave like Cloudflare's. A personal stage runs the same Workers, queue, Durable Objects and R2 as prod, so every stage is measured on the real thing.

## What each stage measures

- **Read:** not run. HealthKit reads were measured on the owner's iPhone in prod: 0.3 s per 2,000-item page. Real Health data must never go to staging or a preview, so the benchmark doesn't go through an iPhone; the table repeats that number for comparison.
- **Data:** `Services/api/scripts/synthetic-health.ts` makes batch files exactly as `HealthBatchWriter` does: gzip NDJSON of upserts in the push format with sorted keys, a type at a time in time order, 10,000-record pages cut into files of at most 5,000 records (and 15 MB), and each file's source revisions and devices once, as `health_provenance` records the rows refer to. The mix is roughly a Watch wearer's: heart rate (38%), active and resting energy, distance, steps, sleep and stand hours, the iPhone's 30-minute sums (`health_statistic`), and a few workouts. Values are made up; a test applies a run's files through the real ingestion and checks no line is rejected. Lines are about 450 bytes before compression, like real ones (372–490), but compress to about 32 bytes, which real data, with more varied values and metadata, wouldn't.
- **Upload:** `PUT /v1/health/batches/<id>` for every file, 4 at a time, from the first request to the last `202`. Per-batch latency (p50, p90) and retries (429, 5xx) are in the notes. It's what the iPhone's uploads cost the server, from a Mac on a fast connection: the iPhone's own network and `URLSession` aren't in it.
- **Apply:** from the first batch's `receivedAt` to the last batch's `finishedAt`, both server time, from each batch's status (`GET /v1/health/batches/<id>`). It's the whole ingest pipeline: the queue, the consumer and the store's transactions. Uploads finish well before (the notes say how long), so this is the server's rate, not the uploads'. A failed batch or a rejected line fails the run, since the data is meant to apply.
- **Snapshot:** a store writes a snapshot once it has been quiet for 2 minutes (`docs/sync/protocol.md`). From the snapshot's `createdAt` (when the store started it) to when `GET /v1/sync/snapshot` first returned it, polled every 0.5 s. The wait for quiet is policy, not throughput: it's in the notes, and left out of the wall clock's second figure.
- **Mac download, insert, bootstrap:** `SyncBootstrapBenchmark` (`LilPackage/Tests/Health/HealthDatabaseTests`), built and run in Release, drives the Mac's real `LilSyncEngine.bootstrap()` with lil health's entities into a new database on disk, against the stage with the synthetic user's token. Download is from the start until the last part arrived (4 at a time, each checked against its SHA-256); insert is the rest: clearing the tables, decompressing every record into a staging table, 5,000 per transaction, then moving them into the tables in one (851-2859). The benchmark builds it before anything is timed. It checks the new database holds exactly as many records as the snapshot, and says which tables differ if not.
- **Wall clock:** from the first upload until the Mac finished bootstrapping, and the same without the snapshot's wait for quiet.

## Physical limits

- **HealthKit:** 6,700 items/s on the owner's iPhone (prod, above). Every stage after it ran faster than that. Applying (5,500–8,200 items/s) came closest, so it's what would hold a first sync back once the iPhone reads faster or several devices upload.
- **Network:** the uploads move under 1 MB/s and the downloads up to about 10 MB/s, a small fraction of a gigabit connection, so neither is near the network's limit. Both are bound by round trips: an upload by the server's work per batch (two store calls, the R2 put, the queue send, 851-2667), a download by a few small parts at a time.
- **The store:** a user's store is one Durable Object, one thread. Applying cost about 80 µs of CPU per sample after 851-2651 (12,500 items/s), less since grouped upserts and a change log without row copies (851-2671, 851-2673). The best one user has applied is about 9,500 items/s (851-2652, step samples only). It's the stage furthest below the others.
- **The Mac:** SQLite on an SSD. A sample costs about 9 µs to upsert through a prepared statement (851-2649), so about 100,000 items/s for the writes alone. Loading a snapshot costs about 30 µs a record, nearly all of it decoding JSON, at any size since 851-2859.

## Results

**Prod**, during the owner's first upload (6.5M items), per 2,000-item page, before the snapshot's wait for quiet (measured for the ticket): 0.3 s read (6,700 items/s), 1.6 s upload (1,250 items/s; 11 ms of CPU, the rest waiting on the store), 4.4 s apply (450 items/s). The store's alarm ran 911 times an hour at 1.3 s each, re-snapshotting everything stored so far, which is what the quiet period stopped.

**2026-10-21**, personal stage (`live_tuftlord`) running `main` at 8176b88 (deployed as `d3fb94b-dirty`: the benchmark's first commit, with only its own scripts and docs changed). Apple M1 Pro (10 cores, 16 GB), macOS 27, on gigabit Ethernet. 4 uploads at once. Items per second:

| Stage | 200,000 records (run 1) | 200,000 (run 2) | 200,000 (run 3) | 1,000,000 |
| --- | ---: | ---: | ---: | ---: |
| Read (HealthKit, on device, not run) | 6,667 | 6,667 | 6,667 | 6,667 |
| Upload | 18,481 (10.8 s) | 22,938 (8.7 s) | 24,758 (8.1 s) | 22,260 (44.9 s) |
| Apply | 7,439 (26.9 s) | 6,146 (32.5 s) | 5,545 (36.1 s) | 8,209 (121.8 s) |
| Snapshot | 21,259 (9.4 s) | 18,730 (10.7 s) | 17,325 (11.5 s) | 24,291 (41.2 s) |
| Mac download | 141,236 (1.4 s) | 112,209 (1.8 s) | 132,808 (1.5 s) | 280,133 (3.6 s) |
| Mac insert | 27,475 (7.3 s) | 23,085 (8.7 s) | 24,513 (8.2 s) | 15,538 (64.4 s) |
| Mac bootstrap | 23,001 (8.7 s) | 19,146 (10.4 s) | 20,694 (9.7 s) | 14,721 (67.9 s) |
| Wall clock | 177 s (57 s without the quiet period) | 186 s (66 s) | 195 s (75 s) | 367 s (247 s) |

Runs 1, 2 and the 1,000,000 timed applying to the change log's last change; run 3, after code review, to the last batch's `finishedAt`, which comes a moment later.

- Uploads finished 17–78 s before applying did: with 4 in flight, the queue is always full, so applying sets the pace (per batch p50 0.5–0.7 s, p90 about 1 s, no retries).
- Applying is 14–18 times prod's 450 items/s. Prod's store held millions of rows and was re-snapshotting every few seconds, so the two aren't the same load; a run with `--records 6500000` would come closer.
- The Mac's inserts slow down as its tables grow: 36 µs a record at 200,000, 64 µs at 1,000,000. That's the one stage that got slower with size. Fixed in 851-2859, below.

**2026-10-21**, the Mac's inserts alone (851-2859), `SyncLoadBenchmark` in Release, on the same Mac, busy with other builds throughout (load averages of 300–1,000). Three runs each, the median first:

| | 200,000 records | 1,000,000 records |
| --- | ---: | ---: |
| Before, µs a record | 89 (30, 166) | 189 (187, 190) |
| Before, pages read and written a record | 0.03–0.09, 0.27 | 0.98, 0.67 |
| After, µs a record | 30 (27, 30) | 30 (30, 73) |
| After, pages read and written a record | 0.00, 0.08 | 0.14, 0.12 |

- **Cause:** samples arrive in the store's key order (type, then start date), so their random HealthKit IDs land all over the primary key's index. Each 5,000-record transaction dirtied thousands of the index's pages, read most of them back from disk once the index outgrew SQLite's 2 MB page cache, wrote them to the write-ahead log, and checkpointed them (with an `F_FULLFSYNC`), since every commit wrote more than the 1,000 pages that trigger a checkpoint. A 15 s profile of a 1,000,000-record load (`sample`) had 42% of the writer's time in commits, 35% in those checkpoints (26% in the sync alone), and 18% reading index pages back. The bigger the index, the more of its pages a batch touched: 0.27 pages written a record at 200,000, 0.67 at 1,000,000, and 0.09 pages read against 0.98. A run with the samples sorted by ID, and without the other indexes, wrote 0.06.
- **Fix:** records go to a staging table first, in the writer's temporary schema, without indexes, so each insert appends and nothing is synced. One transaction then moves them into their table in primary key order, so the table and its key's index are appended to, with the table's other indexes dropped first and built again afterwards, which sorts once. That transaction took about 7 s of the 1,000,000-record load. The write-ahead log, which grows as big as the records, is truncated afterwards.
- A bigger page cache alone (256 MB) cut pages read to 0.29 a record but left the writes as they were.
- Earlier, while the Mac was less busy, the old code took 30 µs a record at 200,000 and 68–89 µs at 1,000,000, like the stage's 36 and 64. Its I/O made it suffer most from a busy disk.

- The snapshot's 2-minute wait for quiet is most of the wall clock at these sizes. It's policy rather than throughput: without it the store re-snapshots while ingesting, as in prod.

## Agent tool calls

What the remote MCP server's heaviest calls cost a user's store (851-2906). A store is reset when its CPU time since its last incoming request passes 30 seconds (`docs/decisions/server.md`, MCP servers), so one call must stay far below that.

**Measuring it:** a stage of its own (`alchemy deploy --stage <name>`, preview environment), 1,000,000 records from `scripts/bench-sync --url <stage> --skip-mac --keep`, an agent connected to the benchmark's account through `/oauth/authorize` with test-account sign-in, then each call one at a time, three rounds. CPU time is the store's, from each `/health` request's event in Workers Logs (`cpuTimeMs`). The benchmark's data has the iPhone's 30-minute sums but no statistics device, so steps and energy come from their samples: the most a call can read, as for an account whose iPhone hasn't reported statistics.

**2026-10-21**, stage `perf-2906`, the same store before (`main` at cb7ecff) and after the change. CPU per call in ms, per round:

| Call | Samples read | Before | After |
| --- | ---: | ---: | ---: |
| `metric` heart rate, Y (average) | 105,000 | 881, 576 | 474, 312, 432 |
| `metric` heart rate, Y (maximum) | 105,000 | 594, 466 | 405, 335, 263 |
| `metric` heart rate, 6M | 52,000 | 276, 226 | 171, 133, 231 |
| `metric` steps, Y | 81,600 | 7,194, 7,262 | 226, 201, 315 |
| `metric` steps, 6M (average) | 81,600 | 6,573 | 329, 296, 220 |
| `metric` active energy, Y | 204,000 | 18,384, 18,403 | 652, 648, 449 |
| `metric` basal energy, Y | 142,900 | not run | 431, 422, 288 |
| `sleep`, Y | 25,500 | 1,870, 2,254 | 394, 332 |
| `samples` heart rate, Y (500) | 500 | 58, 64 | 50, 43, 84 |
| `workouts`, Y | 360 | 25, 20 | 26, 50, 22 |
| `summary`, `search` | | 6–18 | 6–12 |

Rounds missing from Workers Logs are left out. Every answer was the same before and after.

**Where the time went**, profiled locally (Node, the same 1,000,000 records ingested through the real ingestion, thread CPU time, Apple M1 Pro):

- **Time-zone math per row:** a year of steps cost 2.3–2.7 s, of which reading its 81,632 samples took 0.1 s and the rest was `startOfDay` for every sample (30–35 µs each, through Effect's `DateTime` in the call's time zone). Active and basal energy, with more samples, cost more in proportion; prod's 5.8 s calls and the benchmark's 7 s steps were this. `sleep` did the same per record. Now `dayStarts` works out each day's start and end once, and rows, which come in time order, are placed by comparison: under 400 time-zone calculations for a year. A year of steps went to 0.11–0.13 s.
- **Reading rows:** most of what's left. A year of heart rate (105,000 samples) took 0.14 s of its 0.17 s locally. Statistics now read rows as arrays of values (`StoreSql.rows`, workerd's `raw()`), not an object per row, and cumulative types read only the start and value. On the stage that took a year of heart rate from about 0.5 s to 0.3–0.5 s, and active energy's year from about 0.75 s to 0.45–0.65 s.
- **Bucketing and weighting:** not buckets × readings before either (each bucket found its readings by binary search), but each bucket copied its readings and weighed them again. Now one pass over the readings adds each to its bucket and to the period, with each source's next reading found once. A time-weighted reading's weight still depends on whether its source's next reading starts within an hour of its bucket's end, as the Mac weighs each bucket on its own, and sums are added in the same order, so answers are identical: all 37 conformance cases, and the old and new code compared on the 1,000,000 records for heart rate, steps and basal energy, every range, six time zones (Lord Howe's half-hour change included) and days around changes of offset.
- **The Mac** (`HealthDatabase`) already walks a period at a time (`Periods`, `CardBucketer` since 851-3195), reads each bucket with its own query, and uses Foundation's calendar, so it had no such loop and is unchanged.

## Cards on the Mac

What a card costs the Mac's engine over a year by the day (851-3195, `docs/decisions/cards.md`): `CardQueriesBenchmark` (`LilPackage/Tests/Health/HealthDatabaseTests`) writes a year of heart rate a minute (525,600 samples, several times what a Watch records) and as many of another type into a new database, then runs cards with a 7-day moving average over the year, five times each, and prints the median's CPU time (the thread's, so other processes don't count):

```sh
cd LilPackage
LIL_BENCHMARKS=1 swift test -c release --filter CardQueriesBenchmark
```

**2026-10-23**, Apple M1 Pro, shared with other agents' builds (load 40–120). CPU ms:

| Card | Total | Fetching |
| --- | ---: | ---: |
| SQLite alone reading the year's rows (the floor) | 106 | |
| Heart rate, `avg` | 190 | 156 |
| Heart rate, `max`, `deviceModels: ["Watch"]` (each row's device through `json_extract`) | 278 | 215 |
| Heart rate, `first`, `00:00` to `12:00` (sample IDs read) | 231 | 185 |

**Windows** (851-3196), with a year of a Watch's nights (10 records each) and a 45-minute workout a day, alternately running and cycling, in the same database. Rerun **2026-10-23** on the same Mac (load 20–100); the rows above came out within 10 ms of their first run. CPU ms, fetching included:

| Card | Total |
| --- | ---: |
| Heart rate, `asleep`, by the night (about 150,000 readings, 365 points) | 85 |
| Heart rate, `beforeSleep` 5 minutes, by the night | 8 |
| Heart rate, `workout` of running, by the day | 5 |

- **Only the stretches are read:** the nights' records first (about 3,700 rows), then a range of the index per stretch. Reading each night's stretches asleep as one range, and dropping the minutes awake between them, took 88 ms against 85, within the noise, so it's a range per stretch.

- **Reading by column** from the statement, with one string per run of a source's rows, took fetching from 73 ms over SQLite's floor (a GRDB `Row` each, and a string each) to 42 ms. Computing the points from the readings takes the rest, 35–60 ms: the weights number each reading's source rather than hashing its bundle ID, and only `first` and `latest` keep readings in their buckets.
- **A covering index** of `(type, startDate, endDate, value, sourceBundleID)` took SQLite's part from 97 ms to 57 ms, but would store every sample's type and bundle ID a second time, hundreds of MB on a real Mac's millions of samples, so there's none.

## Cards on the server

What a card costs the server's engine (851-3197, `docs/decisions/cards.md`, The server), on the Mac's benchmark data (above) in a `node:sqlite` store: a year of heart rate a minute (525,600 samples) and as many of active energy, a year of a Watch's nights and a 45-minute workout a day. `CardEngineBenchmark` (`Services/api/test/health/cards`) runs each card over Y, with a 7-day moving average, five times, and prints the median's CPU time (the process's):

```sh
cd Services/api
LIL_BENCHMARKS=1 vp test --reporter=verbose --silent=false test/health/cards/CardEngineBenchmark.test.ts
```

**2026-10-23**, Apple M1 Pro, very busy with other agents' builds (load 430–650, so every figure is high). CPU ms:

| Card | Total |
| --- | ---: |
| SQLite alone reading the year's rows as arrays (the floor) | 693 |
| Heart rate, `avg`, by the day | 925 |
| Heart rate, `avg`, `auto` (by the month) | 766 |
| Heart rate, `max`, `deviceModels: ["Watch"]`, by the day | 748 |
| Heart rate, `first`, `00:00` to `12:00`, by the day | 996 |
| Heart rate, `asleep`, by the night | 285 |
| Heart rate, `beforeSleep` 5 minutes, by the night | 121 |
| Heart rate, `workout` of running, by the day | 59 |
| Active energy from its samples, by the day | 577 |

- **Reading the rows is most of it,** as for the Health tools (above): the engine adds 50–300 ms over the floor for half a million readings. Time-zone math is per bucket and night, not per reading.
- **A real account** has about 105,000 heart rate samples a year (Agent tool calls, above), a fifth of these, so a year's card costs about what a year of `metric` does, well under the store's 30 s limit and inside the tools' 0.7 s.

## Snapshot tests: from an edit to an image

How long an agent or a person waits between saving a one-line change to a view and seeing its snapshot compared with the reference (851-2962). Snapshot tests replace `RenderPreview` only if this loop is no slower than `RenderPreview`'s.

**Measuring it:** a shell loop toggles a visible one-line change and times the command until it exits, alternating the two edits, each followed by the old command and then the new one, so each sees one change. The edits: `HealthNotificationsView`'s row padding (`HealthPages`, 50 files; the state `notificationsList`, now the `notifications` catalog's "High heart rate notifications", 851-2965), and the access log's date style in `AgentAccessSettingsView` (`HealthMacApp`, 27 files; `agentsPane`, now the `settings` catalog's "Agents: on, with a log", 851-2966). Each test renders its state in light and dark. Load averages are the 1-minute figure when the command started. (The MacBook's first three rounds edited a line of the same file that the state doesn't show; the build is the same.)

- **Before:** `swift test --filter <state>`, as AGENTS.md said.
- **After:** `scripts/snapshot <state>`.
- **`RenderPreview`:** the same edit, then Xcode's `RenderPreview` (MCP) of the preview the test copies, until it returns an image, retrying its 60-second timeouts.

**2026-10-21, a Mac mini** (M6, 12 cores, macOS 27, nothing else running but the odd CI job; load 3–6), five rounds, seconds, median (range):

| Edit | Before | After |
| --- | ---: | ---: |
| `HealthPages` | 9.3 (9.2–10.2) | 6.3 (6.3–12.4) |
| `HealthMacApp` | 8.2 (8.0–10.0) | 5.4 (5.2–5.4) |

Where the 6.3 s of a `HealthPages` edit go, from `swift build -v`'s output on the same mini: SwiftPM loading the package's manifests (1.5 s), planning the build (0.5 s), the driver planning the module (0.4 s), compiling the file and emitting the module's interface at once (1.9 s), relinking the three test bundles that link `HealthPages` and the two library products (0.3–1 s), then starting the test process (0.4 s) and rendering the two images (0.3 s). `HealthMacApp`'s file compiled in 0.7 s, and fewer bundles link it. Before, `swift test` spent another 3–4 s after the same build: it lists each of the 23 test bundles' XCTest tests, then starts each bundle again for Swift Testing, filtered, though only one has the test.

**2026-10-21, the MacBook Pro** (M1 Pro, 10 cores, 16 GB, macOS 27), shared with other agents' builds and simulators throughout, at loads of 200–900: no quiet moment came. Seconds, median (range), with the loads:

| Edit | Before | After | `RenderPreview`, warm |
| --- | ---: | ---: | ---: |
| `HealthPages` | 27.7 (22.2–41.7), load 300–600 | 29.7 (22.7–52.2), load 210–710 | 39.6 (28.7–47.9), load 220–870 |
| `HealthMacApp` | 24.2 (23.4–52.9), load 290–580 | 15.4 (11.6–20.8), load 220–720 | 37.4 (17.9–55.5), load 220–900 |

- Side by side at the same load (each `RenderPreview` followed by `scripts/snapshot` within a minute): at load 220, 28.7 s against 31.4 s for `HealthPages`, and 17.9 s against 18.9–20.8 s for `HealthMacApp`; at load 650–900, 37.5–47.9 s against 29.7–52.2 s, and 32.1–55.5 s against 11.6 s. So on a busy Mac the two loops take about as long, and either varies by 2x with the load. Both are bound by the build: running the tests took 1–4 s of `scripts/snapshot`'s time (7.6 s once).
- **Opened fresh:** `RenderPreview` in a new worktree's workspace waited 26 s for packages to load, then 204 s for its first image (load 290, rising to 800 as Xcode built). `scripts/snapshot`'s first build in a new worktree took 277 s (load 270), 130 s of it fetching dependencies again and 148 s building; 72 s on the mini. Since 851-2973, `scripts/worktree new` resolves that `.build` from a copy of the last new worktree's: its Swift step took 13 s rather than 75 s (load 120 and 150–270), and the first `swift build --build-tests` started building after 6–17 s rather than 75 s (159–161 s in all, against 217 s, at load 150–400).
- **No edit:** a warm `RenderPreview` returned in 1.3 s; `scripts/snapshot --no-build` in 1.5–2 s.

**The iPhone** (851-2953): `scripts/snapshot --iphone syncStatus` with `LIL_SNAPSHOT_STATE='^Up to date$'` (one state, light and dark), toggling the status header's padding in `SyncStatusView`, so each edit shows. The simulator was already booted. There's no `RenderPreview` baseline: its iPhone renders failed 7 times in 7 in 851-2931, so the iPhone's gate is reliability and a changed screen's image in under about a minute when warm (851-2948's decision 3). Seconds, with how long the build and the test run took:

| Mac | Rounds | Median (range) | Build | Tests |
| --- | ---: | ---: | ---: | ---: |
| Mini (tamale, Xcode 27.1), load 6–14 | 5 | 15.0 (12.3–25.0) | 6–13 | 5–11 |
| MacBook Pro, between other agents' builds | 3 | 24.1 (22.6–43.2) | 13–23 | 8–19 |
| MacBook Pro, load 220–250 | 2 | 38.0, 177.9 | 16–49 | 21–100 |

- **Most of it is `xcodebuild`:** the build (incremental, 5–23 s when quiet) and starting the test runner in the simulator (most of a test run's time: two images take 0.5 s each to settle and draw).
- **All 13 states,** light and dark (26 images): 25–41 s of tests on the MacBook between builds, 20 s on the mini.
- **Cold:** on the mini, with no build and no simulator, 109 s (77 s building, while the new simulator booted alongside, then 31 s of tests). A new simulator with the build warm: 54 s. On the MacBook, the first build took 149 s at load 200–500.
- **Hangs:** at loads of 450–600, the test runner didn't start for over 10 minutes, as in 851-2931, and a booted simulator stopped answering (`simctl spawn` hung). One of the MacBook's rounds hit that: its run was stopped after 5 minutes and passed on a freshly booted simulator, 1351 s in all. That's what the time limit and the retry are for; on a Mac that busy, the loop isn't usable either way.

**What didn't help:**

- Building only the snapshot tests' bundle (`swift build --product HealthSnapshotTests`) is a different build from `swift test`'s (without `ENABLE_TESTABILITY`), so switching between the two rebuilt most of the package (75–90 s on the MacBook, 20–25 s on the mini). In a scratch path of its own it was no faster on the mini: 5–7.5 s against 3.4–5.4 s for `swift build --build-tests`.
- `--disable-automatic-resolution`, `--skip-update` and `--use-integrated-swift-driver` didn't change a no-op build (2.3–2.5 s on the mini).
- Splitting `HealthPages`: an edit in it costs about 1 s more than one in `HealthMacApp`, mostly the edited file's own compile (1.9 s against 0.7 s, with the module's interface emitted alongside), which a smaller module would hardly change. Not done.

**What's left** is SwiftPM: about 3 s of every run on a quiet Mac before anything compiles, and most of it under load. Going below that, towards Xcode's canvas, needs a process that stays running and swaps in the edited code: watch mode, 851-2972.

## Compilation caching

What a new worktree's first build costs, and how much of it a compilation cache shared across worktrees saves (851-3235). `docs/decisions/distribution.md` (Compilation caching) has the decision; `scripts/compilation-cache` the details.

**Measuring it:** builds in two worktrees of the same commit, each starting with its dependencies resolved (as `scripts/worktree new` leaves it) and no build output: **cold** with an empty cache, **warm** in the other worktree with the cache the first one filled. Times are wall clock and the build's CPU time (user), which depends less on what else runs; load averages are the 1-minute figure when the build started, then when it ended. MacBook Pro (M1 Pro, 10 cores, 16 GB), macOS 27, Xcode 27.0 (Swift 6.4, swiftlang-6.4.0.34.1), shared with two other agents' builds, so a few runs each rather than loops.

### What the toolchain offers

- **Swift Build's compilation caching** is the one that applies. Each compile's outputs go into an on-disk CAS (LLVM's) under a key of its inputs: its command line, its sources, and the modules it imports, by content. Explicitly built modules, which it needs, are already the default for both `swift build` and `xcodebuild`.
  - `xcodebuild` turns it on with build settings: `COMPILATION_CACHE_ENABLE_CACHING`, `COMPILATION_CACHE_CAS_PATH`, `COMPILATION_CACHE_LIMIT_SIZE` (`10G` works), with `SWIFT_ENABLE_PREFIX_MAPPING`, `CLANG_ENABLE_PREFIX_MAPPING` and `SWIFT_OTHER_PREFIX_MAPPINGS`/`CLANG_OTHER_PREFIX_MAPPINGS` for paths. A remote cache (`COMPILATION_CACHE_ENABLE_PLUGIN`, `COMPILATION_CACHE_REMOTE_SERVICE_PATH`) needs a CAS service we'd have to run.
  - **SwiftPM** (`swift build`, which builds with Swift Build since Swift 6.4) passes Swift Build only its own settings: neither the environment nor `XCODE_XCCONFIG_FILE` reaches it. Swift Build reads its defaults from the environment, though: `EnableSwiftCachingByDefault=YES`, `EnableClangCachingByDefault=YES`, `CompilationCachingCASPath` and `CompilationCachingDiskSizeLimit` (`10G`) turn caching on, which `swift build -v` shows as `-cache-compile-job -cas-path …` on every compile and `N hits / M cacheable tasks` at the end.
  - The driver's flags through `-Xswiftc` (`-cache-compile-job -cas-path …`) alone don't work: Swift Build's SDK stat cache (`-ivfsstatcache`) isn't in the CAS, and every compile fails ("stat cache file … not found").
- **A shared Clang module cache** doesn't apply: with explicit modules, SDK and Clang modules are built as compiles of their own (`SDKExplicitPrecompiledModules`), so the CAS caches them like any other.
- **Prefix maps** decide whether worktrees share anything. Keys hold every path on a compile's command line: the build folder, the dependencies' checkouts, and `-file-compilation-dir`, the worktree. `-scanner-prefix-map <path>=<replacement>` (through `-Xswiftc` for SwiftPM) rewrites them; the longest prefix wins, so a folder mapped to itself keeps its path inside a mapped one. Mapped, a module's key in one worktree matched the other's exactly (`llvm-cas --diff-graphs` on the two keys: the command lines differed only in the package's name, the same for every worktree's `LilPackage`).
- **What mapping costs:** a mapped source's `#filePath` is the mapped path (`/^root/…`). Tests find their references and fixtures by `#filePath` (snapshot references, `LayoutShiftTests`, the cards' and toolkit's files), so our sources and tests map to themselves, and their compiles are each worktree's own. Diagnostics are mapped back on replay.
- **Macros:** modules that use a macro built in the package (TCA's, CasePaths', SwiftNavigation's, StructuredQueries') are never shared across worktrees: Swift Build passes each macro's path (`-load-plugin-executable …/Products/Debug/CasePathsMacros`) outside the maps, though the resolved one (`-load-resolved-plugin`) is mapped. The prebuilt swift-syntax doesn't change that.
- **A toolchain crash:** with prefix maps, replaying a cached warning whose note points into another module's printed declaration aborted `swift build` (SIGABRT, `bad_optional_access` in `FileSpecificDiagnosticConsumer::subconsumerForLocation`, from `CachingDiagnosticsProcessor::replayCachedDiagnostics`), twice in a row on the same build. Without maps the same replay worked. The warning was `MetricDetailCaptionTests`' (851-3238), which Xcode 27.0 shows and 27.1 doesn't.

### SwiftPM: `swift build --build-tests`, what `scripts/snapshot` and `swift test` build

| Build | Wall | CPU | Cache hits | Load |
| --- | ---: | ---: | ---: | --- |
| No cache | 138 s | 596 s | | 10 → 79 |
| Cold, no maps | 253 s | 645 s | 0 of 1,174 | 8 → 157 |
| Cold, with maps | 203–236 s | 619–632 s | 0 of 1,174 | 174–284 → 560 |
| Warm, other worktree, no maps | 125 s | 583 s | 307 of 1,087 (28%): SDK modules | 25 → 52 |
| Warm, other worktree, our sources mapped too | 165 s | 441 s | 722 of 1,084 (67%) | 562 → 535 |
| Warm, other worktree, dependencies mapped (what shipped) | 107 s | 467 s | 646 of 1,088 (59%) | 259 → 188 |
| Warm, same worktree, no maps (the floor) | 73 s | 182 s | 1,059 of 1,059 (100%) | 157 → 131 |

- Caching costs a cold build 4–8% more CPU.
- Without maps a new worktree shares only the SDK's modules, which are cheap: 2% less CPU.
- With the dependencies mapped, a new worktree's first build takes about a quarter less CPU. What still compiles: our modules and tests (their paths are their own), and the modules that use the package's macros, with what depends on them only when their outputs differ.
- Mapping our sources too gained another 5% of CPU, not worth breaking `#filePath`.
- The cache grew by 1.3–2.3 GB per worktree's full build.

### What shipped: `scripts/swift`, `scripts/xcodebuild`

**2026-10-23**, the scripts as merged, each from a fresh worktree's state (dependencies resolved, no build output), the other worktree filling the cache for **warm**. Seconds, CPU seconds:

| First build in a worktree | No cache | Cold | Warm |
| --- | ---: | ---: | ---: |
| `scripts/snapshot metricDetail`: building (`swift build --build-tests`) | 213 | 431 | 173 |
| … in all, with rendering 100 images | 260 | 537 | 201 |
| … CPU | 645 | 712 | 527 |
| … load | 51 → 72 | 283 → 246 | 245 → 67 |
| Debug lil health (`scripts/xcodebuild -scheme LilHealth … build`, new `.build/DerivedData`) | 120 | 101 | 100 |
| … CPU | 341 | 390 | 262 |
| … cache hits | | 0 of 973 | 658 of 862 (76%) |
| … load | 301 → 180 | 169 → 66 | 62 → 57 |

- **A new worktree's first build takes about a fifth to a quarter less CPU** (18% for `scripts/snapshot`'s, 23% for the app's), and its own modules compile once, then replay whenever their inputs come back (a branch switched back, a cleaned `.build`, `scripts/check`'s `.build-check`, which maps to the same `/^build`). The wall clock moved with the load more than with the cache: the cold `scripts/snapshot` ran under four times the load of the uncached one.
- **The app's wall clock hardly moved:** compiling is under half of it. The rest is resolving the packages into a new DerivedData, planning, scanning, linking and signing.
- **Far from an incremental build**, which is what the ticket hoped for. What keeps it from that, in order of cost: our modules and tests compile per worktree (their paths are their own, for `#filePath`); modules that use the package's macros never share (`-load-plugin-executable`); linking, which no cache covers.
- **Correct:** every `scripts/snapshot` run above matched all 100 of Metric Detail's images; on one commit, HealthDatabaseTests, LilSyncTests, HealthCardsTests and LilAuthTests ran the same 515 tests with and without the cache, with the same results (and the same 9 known issues); CI's Swift check, which builds and tests everything through the scripts, compared every snapshot within 1, Mac and iPhone (851-3235's PR).
- **An Xcode project's folder** under a folder mapped to anything but `/^root`, itself included, fails Clang's dependency scan of its targets ("module-include.input: Operation not supported"), as `Apps` mapped to itself did for the apps' targets and `Tests` for `PhoneSnapshots`' host app. So each test target's folder maps to itself on its own, and the projects' folders as the rest of the worktree.
- **Two builds at once** (both worktrees, load 511 → 724) shared the cache without a problem, and `llvm-cas --validate` found it sound after. One of them was on a commit before 851-3238, so it replayed `MetricDetailCaptionTests`' warning, aborted, and built again without the cache, as the scripts do: 571 s against the other's 231.
- **Size:** 2.1 GB after the first full build, 3.3 GB after four builds of two commits in two worktrees, Debug app builds included. A size limit of 1G on a 2.3 GB cache started a new generation (`cache size … larger than size limit`) at the end of the build; the old one goes when the new one passes the limit in turn.
- **CI:** the minis' builds are already warm (`LIL_CHECK_SCRATCH`), so the cache matters when one pull request undoes another's changes, between main's folder and pull requests', and after a folder starts over. Their Xcode is 27.1, so a laptop's cache is no use to them, or theirs to a laptop.

