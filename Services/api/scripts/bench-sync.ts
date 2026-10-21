// The sync throughput benchmark (851-2650): synthetic Health data from "iPhone" to server to Mac,
// timing each stage. Run it with `scripts/bench-sync` from the repo root; see `docs/BENCHMARK.md`.
//
//   node scripts/bench-sync.ts [--records <n>] [--concurrency <n>] [--url <stage>] [--keep]
//     [--skip-mac] [--seed <n>] [--json <file>]
//
// Without --url (or LIL_BENCH_API_URL) it deploys your personal stage (`live_<user>`) first and
// runs against that. It never runs against prod. It signs in a new synthetic user with dev
// sign-in (previews and personal stages), and deletes it afterwards unless --keep. Staging has no
// dev sign-in: give it LIL_BENCH_REFRESH_TOKEN, a refresh token of a staging account whose data
// may grow, and that account is kept.
import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { arch, cpus, release, tmpdir, totalmem, type } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";
import { gzip } from "node:zlib";
import { snapshotPolicy, type SnapshotPolicy } from "../src/store/Snapshots.ts";
import { syntheticBatches } from "./synthetic-health.ts";

const repo = fileURLToPath(new URL("../../..", import.meta.url));
const apiDirectory = fileURLToPath(new URL("..", import.meta.url));
const compress = promisify(gzip);
const run = promisify(execFile);

// MARK: - Helpers (tested in test/BenchSync.test.ts)

export interface Options {
  readonly url: string | undefined;
  readonly records: number;
  readonly concurrency: number;
  readonly seed: number;
  readonly keep: boolean;
  readonly skipMac: boolean;
  readonly json: string | undefined;
  readonly refreshToken: string | undefined;
}

export const defaultRecords = 200_000;

export const parseOptions = (
  argv: ReadonlyArray<string>,
  environment: Readonly<Record<string, string | undefined>>,
): Options => {
  const { values } = parseArgs({
    args: [...argv],
    options: {
      url: { type: "string" },
      records: { type: "string" },
      concurrency: { type: "string" },
      seed: { type: "string" },
      keep: { type: "boolean", default: false },
      "skip-mac": { type: "boolean", default: false },
      json: { type: "string" },
    },
    strict: true,
  });
  const integer = (name: string, value: string | undefined, fallback: number, min: number) => {
    if (value === undefined) return fallback;
    const parsed = Number(value.replaceAll("_", "").replaceAll(",", ""));
    if (!Number.isInteger(parsed) || parsed < min) {
      throw new Error(`--${name} must be an integer of at least ${min}, not ${value}`);
    }
    return parsed;
  };
  const refreshToken = environment["LIL_BENCH_REFRESH_TOKEN"];
  return {
    url: values.url ?? environment["LIL_BENCH_API_URL"],
    records: integer("records", values.records, defaultRecords, 1),
    concurrency: integer("concurrency", values.concurrency, 4, 1),
    seed: integer("seed", values.seed, Math.floor(Math.random() * 2 ** 31), 0),
    // Someone's own account is never deleted.
    keep: values.keep || refreshToken !== undefined,
    skipMac: values["skip-mac"],
    json: values.json,
    refreshToken,
  };
};

/** The `p`th percentile (0–100) of `values`, by nearest rank. */
export const percentile = (values: ReadonlyArray<number>, p: number) => {
  if (values.length === 0) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length, Math.max(1, rank)) - 1] ?? Number.NaN;
};

export const perSecond = (items: number, seconds: number) =>
  seconds > 0 ? items / seconds : Number.NaN;

/** Refuses prod, by its host or by what the stage says it is. */
export const checkNotProd = (url: string, environment: string | undefined) => {
  const host = new URL(url).host;
  if (host === "api.lil.tech" || environment === "prod") {
    throw new Error(`Refusing to benchmark prod (${url}): its data is real people's`);
  }
};

/** How long to wait before retrying a refused request: the server's `Retry-After`, or backoff. */
export const retryDelay = (
  status: number,
  retryAfterSeconds: number | undefined,
  attempt: number,
) => {
  if (status === 429 && retryAfterSeconds !== undefined) return retryAfterSeconds * 1000;
  return Math.min(30_000, 1000 * 2 ** (attempt - 1));
};

/** How long a refused request asks to wait: the body's `retryAfterSeconds`, or `Retry-After`. */
export const retryAfterSeconds = (body: string, header: string | null) => {
  try {
    const parsed = JSON.parse(body) as { retryAfterSeconds?: unknown } | null;
    if (typeof parsed?.retryAfterSeconds === "number") return parsed.retryAfterSeconds;
  } catch {
    // Not JSON: the header, if any.
  }
  const seconds = Number(header ?? Number.NaN);
  return Number.isFinite(seconds) && seconds > 0 ? seconds : undefined;
};

/**
 * Whether a store writes a snapshot once `changes` have arrived since its latest one (holding
 * `latestRecords`, if it has one), as `nextSnapshotAt` decides: at least `minChanges`, and a
 * quarter of the latest's records.
 */
export const snapshotDue = (
  changes: number,
  latestRecords: number | undefined,
  policy: Pick<SnapshotPolicy, "minChanges" | "changeShare"> = snapshotPolicy,
) => changes >= Math.max(policy.minChanges, Math.ceil((latestRecords ?? 0) * policy.changeShare));

export interface Row {
  readonly stage: string;
  readonly items: number | undefined;
  readonly seconds: number | undefined;
  readonly note: string;
}

const number = (value: number, digits = 0) =>
  Number.isFinite(value)
    ? value.toLocaleString("en-US", {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
      })
    : "–";

/** A Markdown table of the stages, with items per second. */
export const formatTable = (rows: ReadonlyArray<Row>) => {
  const cells = rows.map((row) => [
    row.stage,
    row.items === undefined ? "–" : number(row.items),
    row.seconds === undefined ? "–" : number(row.seconds, 1),
    row.items === undefined || row.seconds === undefined
      ? "–"
      : number(perSecond(row.items, row.seconds)),
    row.note,
  ]);
  const header = ["Stage", "Items", "Seconds", "Items/s", "Notes"];
  const widths = header.map((title, column) =>
    Math.max(title.length, ...cells.map((cell) => (cell[column] ?? "").length)),
  );
  const line = (cell: ReadonlyArray<string>) =>
    `| ${cell
      .map((text, column) =>
        column >= 1 && column <= 3
          ? text.padStart(widths[column] ?? 0)
          : text.padEnd(widths[column] ?? 0),
      )
      .join(" | ")} |`;
  const rule = `|${widths.map((width, column) => (column >= 1 && column <= 3 ? `${"-".repeat(width + 1)}:` : "-".repeat(width + 2))).join("|")}|`;
  return [line(header), rule, ...cells.map(line)].join("\n");
};

// MARK: - The API

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

interface Tokens {
  readonly accessToken: string;
  readonly accessTokenExpiresAt: number;
  readonly refreshToken: string;
}

class HttpError extends Error {
  readonly status: number;

  constructor(status: number, body: string, what: string) {
    super(`${what}: ${status} ${body.slice(0, 500)}`);
    this.status = status;
  }
}

/** The synthetic user's session on the stage, refreshing its access token when it's old. */
class Stage {
  private tokens: Tokens | undefined;
  /** The refresh in flight, shared: a refresh token works once, and reusing it ends the session. */
  private refreshing: Promise<Tokens> | undefined;
  /** Requests retried after a 429, 5xx or network failure. */
  retries = 0;

  readonly url: string;

  constructor(url: string) {
    this.url = url;
  }

  signedIn(tokens: Tokens) {
    this.tokens = tokens;
  }

  /** The current refresh token, which each refresh replaces. */
  get refreshToken() {
    return this.tokens?.refreshToken;
  }

  /** A current access token, refreshed if it expires within `margin`. */
  async accessToken(margin = 60_000): Promise<string> {
    const tokens = this.tokens;
    if (tokens === undefined) throw new Error("Not signed in");
    if (tokens.accessTokenExpiresAt - Date.now() >= margin) return tokens.accessToken;
    this.refreshing ??= (
      this.request("POST", "/v1/auth/refresh", {
        json: { refreshToken: tokens.refreshToken },
        authenticated: false,
        // A retry after the server refreshed would reuse the token.
        retry: false,
      }) as Promise<Tokens>
    ).finally(() => {
      this.refreshing = undefined;
    });
    this.tokens = await this.refreshing;
    return this.tokens.accessToken;
  }

  /** Sends a request, retrying rate limits, 5xx and network failures. Returns the JSON body. */
  async request(
    method: string,
    path: string,
    options: {
      readonly json?: unknown;
      readonly body?: Uint8Array;
      readonly contentType?: string;
      readonly authenticated?: boolean;
      /** Statuses answered as they are, rather than retried or thrown. */
      readonly accept?: ReadonlyArray<number>;
      /** Whether to retry failures (default true). */
      readonly retry?: boolean;
    } = {},
  ): Promise<unknown> {
    const attempts = options.retry === false ? 1 : 6;
    for (let attempt = 1; ; attempt++) {
      const headers: Record<string, string> = {};
      if (options.authenticated !== false) {
        headers["authorization"] = `Bearer ${await this.accessToken()}`;
      }
      let body: string | Uint8Array<ArrayBuffer> | undefined;
      if (options.json !== undefined) {
        headers["content-type"] = "application/json";
        body = JSON.stringify(options.json);
      } else if (options.body !== undefined) {
        headers["content-type"] = options.contentType ?? "application/octet-stream";
        body = options.body as Uint8Array<ArrayBuffer>;
      }
      let response: Response;
      try {
        response = await fetch(`${this.url}${path}`, {
          method,
          headers,
          ...(body === undefined ? {} : { body }),
        });
      } catch (error) {
        if (attempt >= attempts) throw error;
        this.retries++;
        await sleep(retryDelay(0, undefined, attempt));
        continue;
      }
      const text = await response.text();
      if (response.ok || options.accept?.includes(response.status)) {
        return text === "" ? undefined : (JSON.parse(text) as unknown);
      }
      const retryable = response.status === 429 || response.status >= 500;
      if (!retryable || attempt >= attempts)
        throw new HttpError(response.status, text, `${method} ${path}`);
      this.retries++;
      const retryAfter = retryAfterSeconds(text, response.headers.get("retry-after"));
      await sleep(retryDelay(response.status, retryAfter, attempt));
    }
  }
}

interface ChangesPage {
  readonly head: number;
  readonly epoch: number;
  readonly changes: ReadonlyArray<{ readonly seq: number; readonly at: number }>;
}

interface LatestSnapshot {
  readonly snapshot?: {
    readonly id: string;
    readonly seq: number;
    readonly createdAt: number;
    readonly entities: ReadonlyArray<{
      readonly entity: string;
      readonly parts: ReadonlyArray<{ readonly records: number; readonly bytes: number }>;
    }>;
  };
}

type Snapshot = NonNullable<LatestSnapshot["snapshot"]>;

const snapshotRecords = (snapshot: Snapshot | undefined) =>
  snapshot?.entities.reduce(
    (total, entity) => total + entity.parts.reduce((sum, part) => sum + part.records, 0),
    0,
  );

/** The latest published snapshot, or `undefined` if the store has none yet. */
const latestSnapshot = async (stage: Stage): Promise<Snapshot | undefined> => {
  for (let attempt = 1; ; attempt++) {
    const latest = (await stage.request("GET", "/v1/sync/snapshot", { accept: [503] })) as
      | (LatestSnapshot & { readonly _tag?: string })
      | undefined;
    // 503 is also an unavailable store, which is worth asking again.
    if (latest?._tag === undefined) return latest?.snapshot;
    if (latest._tag === "SnapshotNotReady") return undefined;
    if (attempt >= 6) throw new Error(`GET /v1/sync/snapshot: ${latest._tag}`);
    await sleep(retryDelay(503, undefined, attempt));
  }
};

/**
 * The change log's head. Asked from the latest snapshot's `seq` on: changes it covers may have
 * been compacted away, and asking from before them fails.
 */
const changeHead = async (stage: Stage) => {
  const after = (await latestSnapshot(stage))?.seq ?? 0;
  const page = (await stage.request(
    "GET",
    `/v1/sync/changes?after=${after}&limit=1`,
  )) as ChangesPage;
  return page.head;
};

// MARK: - Stages

const log = (message: string) =>
  console.log(`[${new Date().toISOString().slice(11, 19)}] ${message}`);

/** Deploys the personal stage (`live_<user>`) and returns its API's URL. */
const deployPersonalStage = async () => {
  const { stdout: version } = await run(
    "git",
    ["describe", "--always", "--dirty", "--exclude", "*"],
    { cwd: repo },
  );
  const logFile = join(tmpdir(), `lil-bench-deploy-${Date.now()}.log`);
  log(`Deploying your personal stage (log: ${logFile})…`);
  const output = await new Promise<string>((resolve, reject) => {
    const child = spawn("npx", ["alchemy", "deploy", "--yes"], {
      cwd: apiDirectory,
      env: {
        ...process.env,
        LIL_ENVIRONMENT: "preview",
        LIL_VERSION: version.trim(),
        DO_NOT_TRACK: "1",
      },
    });
    const file = createWriteStream(logFile);
    let text = "";
    const collect = (chunk: Buffer) => {
      text += chunk.toString();
      file.write(chunk);
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    child.on("error", reject);
    child.on("close", (code) => {
      file.end();
      if (code === 0) resolve(text);
      else reject(new Error(`Deploying failed (exit ${code}); see ${logFile}`));
    });
  });
  // The stack's outputs end the log, as in CI: `  url: 'https://…',`.
  const url = [...output.matchAll(/^ {2}url: '(https:[^']+)'/gm)].at(-1)?.[1];
  if (url === undefined) throw new Error(`Couldn't find the stage's URL in ${logFile}`);
  return url;
};

const swiftTest = (environment: Record<string, string>, logFile: string) =>
  new Promise<void>((resolve, reject) => {
    const child = spawn(
      "swift",
      [
        "test",
        "-c",
        "release",
        "--package-path",
        "LilPackage",
        "--filter",
        "SyncBootstrapBenchmark",
      ],
      { cwd: repo, env: { ...process.env, ...environment } },
    );
    const file = createWriteStream(logFile);
    child.stdout.pipe(file);
    child.stderr.pipe(file);
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`swift test failed (exit ${code}); see ${logFile}`)),
    );
  });

interface Upload {
  readonly id: string;
  readonly records: number;
  readonly bytes: number;
  readonly start: number;
  readonly end: number;
  readonly receivedAt: number;
}

/** Set to stop starting uploads: after one failed for good, or on Ctrl-C. */
interface Stop {
  stopped: boolean;
}

/**
 * Uploads every batch, `concurrency` at a time, as the iPhone's backfill does. If one fails, the
 * others stop and are waited for, so none lands after the account is deleted.
 */
const uploadAll = async (stage: Stage, options: Options, stop: Stop) => {
  const batches = syntheticBatches({
    records: options.records,
    seed: options.seed,
    end: Date.UTC(2026, 9, 1),
    run: randomUUID(),
  });
  const uploads: Array<Upload> = [];
  let records = 0;
  let lastReport = Date.now();
  let failure: unknown;
  const worker = async () => {
    while (!stop.stopped) {
      const next = batches.next();
      if (next.done === true) return;
      const file = next.value;
      const body = new Uint8Array(await compress(file.text));
      const id = randomUUID();
      const start = performance.now();
      const batch = (await stage.request("PUT", `/v1/health/batches/${id}`, {
        body,
        contentType: "application/gzip",
      })) as { receivedAt: number };
      uploads.push({
        id,
        records: file.records,
        bytes: body.length,
        start,
        end: performance.now(),
        receivedAt: batch.receivedAt,
      });
      records += file.records;
      if (Date.now() - lastReport > 5000) {
        lastReport = Date.now();
        log(`  uploaded ${number(records)} of ${number(options.records)}`);
      }
    }
  };
  await Promise.all(
    Array.from({ length: options.concurrency }, () =>
      worker().catch((error: unknown) => {
        failure ??= error;
        stop.stopped = true;
      }),
    ),
  );
  if (failure !== undefined) throw failure;
  if (stop.stopped) throw new Error("Stopped");
  return uploads;
};

interface BatchStatus {
  readonly status: string;
  readonly finishedAt?: number;
  readonly rejected?: number;
  readonly rejectedLines?: ReadonlyArray<unknown>;
  readonly failure?: string;
}

/**
 * Waits until every batch is applied, returning when the last one finished (server time). Asks
 * about them in the order they were received, the order they apply in, so it asks about each
 * about once. A failed batch, or a rejected line, fails the run: the data is meant to apply.
 */
const waitForApply = async (stage: Stage, uploads: ReadonlyArray<Upload>) => {
  const ordered = [...uploads].sort((a, b) => a.receivedAt - b.receivedAt);
  let finishedAt = 0;
  let lastProgress = Date.now();
  let lastReport = 0;
  for (const [index, upload] of ordered.entries()) {
    for (;;) {
      const batch = (await stage.request("GET", `/v1/health/batches/${upload.id}`)) as BatchStatus;
      if (batch.status === "failed") {
        throw new Error(`Batch ${upload.id} failed: ${batch.failure ?? "no reason given"}`);
      }
      if (batch.status === "applied") {
        if ((batch.rejected ?? 0) > 0) {
          throw new Error(
            `Batch ${upload.id} rejected ${batch.rejected} lines: ${JSON.stringify(batch.rejectedLines?.slice(0, 3))}`,
          );
        }
        finishedAt = Math.max(finishedAt, batch.finishedAt ?? 0);
        lastProgress = Date.now();
        break;
      }
      if (Date.now() - lastProgress > 5 * 60_000) {
        throw new Error(`Batch ${upload.id} was still ${batch.status} after 5 minutes`);
      }
      if (Date.now() - lastReport > 5000) {
        lastReport = Date.now();
        log(`  applied ${index} of ${ordered.length} batches`);
      }
      await sleep(500);
    }
  }
  return finishedAt;
};

/** Waits for a published snapshot covering `seq`, returning it and when it was first seen. */
const waitForSnapshot = async (stage: Stage, seq: number, deadline: number) => {
  let lastReport = 0;
  for (;;) {
    const snapshot = await latestSnapshot(stage);
    if (snapshot !== undefined && snapshot.seq >= seq) return { snapshot, seenAt: Date.now() };
    if (Date.now() > deadline)
      throw new Error("No snapshot covering the data was published in time");
    if (Date.now() - lastReport > 15_000) {
      lastReport = Date.now();
      log("  waiting for the snapshot…");
    }
    await sleep(500);
  }
};

const usage = `Usage: scripts/bench-sync [--records <n>] [--concurrency <n>] [--url <stage>] [--keep]
                          [--skip-mac] [--seed <n>] [--json <file>]
See docs/BENCHMARK.md.`;

const main = async () => {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    console.log(usage);
    return;
  }
  const options = parseOptions(process.argv.slice(2), process.env);
  const url = (options.url ?? (await deployPersonalStage())).replace(/\/+$/, "");
  checkNotProd(url, undefined);
  const stage = new Stage(url);
  const status = (await stage.request("GET", "/v1/status", { authenticated: false })) as {
    environment: string;
    version: string;
  };
  checkNotProd(url, status.environment);
  const { stdout: commit } = await run("git", ["rev-parse", "--short", "HEAD"], { cwd: repo });
  log(
    `Stage ${url} (${status.environment}, ${status.version}); ${number(options.records)} records, ${options.concurrency} uploads at once, seed ${options.seed}`,
  );

  const scratch = await mkdtemp(join(tmpdir(), "lil-bench-sync-"));
  const macLog = join(scratch, "swift-test.log");
  const runMac = !options.skipMac && options.records >= snapshotPolicy.minChanges;
  if (runMac) {
    // Built before anything is timed, so compiling doesn't compete with the stages.
    log(`Building the Mac's bootstrap benchmark in Release (log: ${macLog})…`);
    await swiftTest({}, macLog);
  }

  let deleteAccount = false;
  const cleanUp = async () => {
    if (!deleteAccount) return;
    deleteAccount = false;
    try {
      await stage.request("DELETE", "/v1/me");
      log("Deleted the synthetic account");
    } catch (error) {
      console.error(`Couldn't delete the synthetic account: ${String(error)}`);
    }
  };
  const stop: Stop = { stopped: false };
  process.once("SIGINT", () => {
    stop.stopped = true;
    void cleanUp()
      .then(() => rm(scratch, { recursive: true, force: true }))
      .finally(() => process.exit(130));
  });

  try {
    const account = `bench-${new Date().toISOString().replaceAll(/[:.]/g, "-")}`;
    if (options.refreshToken === undefined) {
      stage.signedIn(
        (await stage.request("POST", "/v1/auth/dev", {
          json: { account, app: "health-ios", platform: "ios" },
          authenticated: false,
        })) as Tokens,
      );
      deleteAccount = !options.keep;
      log(`Signed in as the synthetic account ${account}`);
    } else {
      stage.signedIn({
        accessToken: "",
        accessTokenExpiresAt: 0,
        refreshToken: options.refreshToken,
      });
      log("Signed in with LIL_BENCH_REFRESH_TOKEN");
    }
    const consent = (await stage.request("GET", "/v1/me/consents/health")) as { required: string };
    await stage.request("POST", "/v1/me/consents/health", {
      json: { policyVersion: consent.required },
    });
    // An account kept from earlier runs needs more changes for its next snapshot.
    const previous = await latestSnapshot(stage);

    // Upload.
    log("Uploading…");
    const retriesBefore = stage.retries;
    const uploads = await uploadAll(stage, options, stop);
    const uploadStart = Math.min(...uploads.map((upload) => upload.start));
    const uploadEnd = Math.max(...uploads.map((upload) => upload.end));
    const uploadEndAt = Date.now() - (performance.now() - uploadEnd);
    const latencies = uploads.map((upload) => (upload.end - upload.start) / 1000);
    const bytes = uploads.reduce((sum, upload) => sum + upload.bytes, 0);
    const uploadRetries = stage.retries - retriesBefore;

    log(`Waiting for the store to apply ${uploads.length} batches…`);
    const applied = { at: await waitForApply(stage, uploads) };
    const head = await changeHead(stage);
    const firstReceived = Math.min(...uploads.map((upload) => upload.receivedAt));

    const rows: Array<Row> = [
      {
        stage: "Read (HealthKit, on device)",
        items: 2000,
        seconds: 0.3,
        note: "not run: measured on the owner's iPhone in prod, a 2,000-item page",
      },
      {
        stage: "Upload",
        items: options.records,
        seconds: (uploadEnd - uploadStart) / 1000,
        note: `${uploads.length} batches, ${number(bytes / 1e6, 1)} MB gzip; per batch p50 ${number(percentile(latencies, 50), 2)} s, p90 ${number(percentile(latencies, 90), 2)} s; ${uploadRetries} retried`,
      },
      {
        stage: "Apply",
        items: options.records,
        seconds: (applied.at - firstReceived) / 1000,
        note: `first batch received → last applied; done ${number((applied.at - uploadEndAt) / 1000, 1)} s after the last upload`,
      },
    ];
    let wallEnd = applied.at;
    let quietWait: number | undefined;

    if (!snapshotDue(head - (previous?.seq ?? 0), snapshotRecords(previous))) {
      log(
        `Skipping the snapshot and the Mac: a snapshot needs ${number(snapshotPolicy.minChanges)} changes, and a quarter of the last one's records`,
      );
    } else {
      // Snapshot: written once the store has been quiet for `quietPeriod`.
      log(
        `Waiting for a snapshot (the store waits ${snapshotPolicy.quietPeriod / 1000} s of quiet first)…`,
      );
      const deadline =
        applied.at + snapshotPolicy.quietPeriod + Math.max(10 * 60_000, options.records);
      const { snapshot, seenAt } = await waitForSnapshot(stage, head, deadline);
      const parts = snapshot.entities.flatMap((entity) => entity.parts);
      const records = snapshotRecords(snapshot) ?? 0;
      const snapshotBytes = parts.reduce((sum, part) => sum + part.bytes, 0);
      quietWait = (snapshot.createdAt - applied.at) / 1000;
      rows.push({
        stage: "Snapshot",
        items: records,
        seconds: (seenAt - snapshot.createdAt) / 1000,
        note: `started → published (seen within 0.5 s); ${parts.length} parts, ${number(snapshotBytes / 1e6, 1)} MB; started ${number(quietWait, 1)} s after the last batch applied`,
      });
      wallEnd = seenAt;

      if (runMac) {
        log("Bootstrapping the Mac (LilSyncEngine, Release)…");
        const resultFile = join(scratch, "bootstrap.json");
        await swiftTest(
          {
            LIL_BENCH_SYNC_URL: url,
            // A new token, for its whole 15 minutes.
            LIL_BENCH_SYNC_TOKEN: await stage.accessToken(Number.POSITIVE_INFINITY),
            LIL_BENCH_SYNC_RESULT: resultFile,
          },
          macLog,
        );
        const mac = JSON.parse(await readFile(resultFile, "utf8")) as {
          downloadSeconds: number;
          insertSeconds: number;
          totalSeconds: number;
          parts: number;
          bytes: number;
          records: number;
          tables: Record<string, number>;
        };
        // A new database holds only what the snapshot brought, so every record or a bug.
        if (mac.records !== records) {
          const entities = Object.fromEntries(
            snapshot.entities.map((entity) => [
              entity.entity,
              entity.parts.reduce((sum, part) => sum + part.records, 0),
            ]),
          );
          throw new Error(
            `The Mac has ${mac.records} records of the snapshot's ${records}: ${JSON.stringify(mac.tables)} against ${JSON.stringify(entities)}`,
          );
        }
        rows.push(
          {
            stage: "Mac download",
            items: records,
            seconds: mac.downloadSeconds,
            note: `${mac.parts} parts, 4 at a time, ${number(mac.bytes / 1e6 / mac.downloadSeconds, 1)} MB/s, checked`,
          },
          {
            stage: "Mac insert",
            items: records,
            seconds: mac.insertSeconds,
            note: "decompress and load into SQLite on disk, 5,000 a transaction",
          },
          {
            stage: "Mac bootstrap",
            items: records,
            seconds: mac.totalSeconds,
            note: "LilSyncEngine.bootstrap(), end to end",
          },
        );
        wallEnd = Date.now();
      }
    }

    const wall = (wallEnd - (uploadEndAt - (uploadEnd - uploadStart))) / 1000;
    rows.push({
      stage: "Wall clock",
      items: options.records,
      seconds: wall,
      note:
        quietWait === undefined
          ? "first upload → last batch applied"
          : `first upload → ${runMac ? "Mac bootstrapped" : "snapshot published"}, ${number(wall - quietWait, 1)} s without the snapshot's wait for quiet`,
    });

    const machine = `${cpus()[0]?.model ?? arch()}, ${cpus().length} cores, ${Math.round(totalmem() / 2 ** 30)} GB, ${type()} ${release()}`;
    console.log(
      `\nSync throughput, ${new Date().toISOString().slice(0, 10)}: ${number(options.records)} records, ${options.concurrency} uploads at once, seed ${options.seed}\nStage: ${status.environment} running ${status.version} (${url}); benchmark at ${commit.trim()}\nMachine: ${machine}\n\n${formatTable(rows)}\n`,
    );
    if (options.json !== undefined) {
      await writeFile(
        options.json,
        `${JSON.stringify({ date: new Date().toISOString(), commit: commit.trim(), url, version: status.version, machine, options: { ...options, refreshToken: undefined }, rows }, null, 2)}\n`,
      );
    }
  } finally {
    await cleanUp();
    await rm(scratch, { recursive: true, force: true });
    // Refreshing replaced it, and the old one now ends the session if it's used again.
    if (options.refreshToken !== undefined && stage.refreshToken !== options.refreshToken) {
      console.error(
        `LIL_BENCH_REFRESH_TOKEN is used up. The account's new refresh token, for the next run:\n${stage.refreshToken}`,
      );
    }
  }
};

if (import.meta.main) await main();
