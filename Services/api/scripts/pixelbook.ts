// Pixelbook (851-2696): publishes a commit's state catalog images to R2, where every stage's
// Pixelbook reads them (851-2955). The images are the catalogs' references, committed beside
// them with a manifest per screen (`CatalogManifest` in `HealthSnapshotTests/StateCatalog.swift`),
// so this reads them from the commit, with git, and needs no Mac, Xcode or render. Run through
// `scripts/pixelbook publish`, which works out the commit's key; from `Services/api`:
//   node scripts/pixelbook.ts --key <key> --commit <sha> [--ref <name> [--force-ref]] [--dry-run]
//
// The bucket (prod's, `pixelbookBucketName`) holds:
//   images/<sha256 of the PNG>.png      every image, once: an unchanged screen isn't uploaded again
//   thumbnails/<the same sha256>.png    the image at a quarter of its size, for zoomed-out views
//   snapshots/<key>/<app>.json          an app's manifest: its screens, states and variants
//   snapshots/<key>/index.json          the apps published for that key, written last
//   commits/<sha>.json                  which key a commit's snapshots are under
//   refs/<ref>.json                     the latest commit published from a branch, e.g. main
// A key names what the snapshots come from: the trees of the catalogs and their references.
// Commits that share those trees (a branch and its squash merge, say) share snapshots.
//
// Credentials: see `scripts/cloudflare.ts`. PIXELBOOK_BUCKET uploads to another bucket.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { pixelbookBucketName } from "../src/Deployment.ts";
import { credentials } from "./cloudflare.ts";
import { decodePng, encodePng, shrink } from "./png.ts";

/** One image of a state. */
export interface Variant {
  /** The object key of its image, under `images/`. */
  readonly image: string;
  /** Its thumbnail's, under `thumbnails/`: a quarter of its width and height. */
  readonly thumbnail: string;
  /** In pixels. */
  readonly width: number;
  readonly height: number;
  /** Pixels per point: 2 on a Retina Mac, 3 on most iPhones. */
  readonly scale: number;
}

/** A state of a screen, in each appearance it has a reference in. */
export interface Snapshot {
  /**
   * Stable while the screen's and state's names are: `<screen>.<state>` as slugs, which name its
   * references. Snapshots published from previews (before 851-2955) had the preview's.
   */
  readonly id: string;
  /** The catalog's module, its folder in `Catalogs/`, e.g. `HealthMacApp`. */
  readonly module: string;
  /** The catalog's file, e.g. `MetricDetailCatalog.swift`. Graphs name `module/file`. */
  readonly file: string;
  /** The file the state is written in, from the repository's root. */
  readonly path?: string;
  /** Its `CatalogState("…")`'s line in that file, if it was found. */
  readonly line: number | null;
  /** Its place in its catalog, which a shared list of states can make differ from its line's. */
  readonly order?: number;
  readonly screen: string;
  readonly state: string;
  readonly variants: { readonly light?: Variant; readonly dark?: Variant };
}

/** An app's snapshots for one key. */
export interface Manifest {
  readonly version: 1;
  /** E.g. `health-mac`. */
  readonly app: string;
  readonly platform: "macos" | "ios";
  readonly key: string;
  readonly commit: string;
  readonly snapshots: ReadonlyArray<Snapshot>;
}

/**
 * A catalog's manifest for one screen, as its snapshot test writes it
 * (`__Snapshots__/<catalog file>/<screen>.json`). Paths are from the repository's root.
 */
export interface CatalogManifest {
  readonly app: string;
  readonly screen: string;
  /** `Module/File.swift`, the catalog's folder in `Catalogs/` and its file. */
  readonly catalog: string;
  readonly states: ReadonlyArray<{
    readonly id: string;
    readonly name: string;
    readonly source: string;
    readonly light: string;
    readonly dark: string;
  }>;
}

/** Where catalog manifests are: `LilPackage/Tests/<target>/Catalogs/…/__Snapshots__/<file>/*.json`. */
export const isCatalogManifest = (path: string) =>
  /^LilPackage\/Tests\/[^/]+\/Catalogs\/.+\/__Snapshots__\/[^/]+\/[^/]+\.json$/.test(path);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** Reads a catalog manifest's JSON, or says what's wrong with it. */
export const parseCatalogManifest = (
  json: unknown,
): CatalogManifest | { readonly problem: string } => {
  if (!isRecord(json)) return { problem: "it isn't an object" };
  for (const field of ["app", "screen", "catalog"]) {
    if (typeof json[field] !== "string") return { problem: `its "${field}" isn't a string` };
  }
  const states = json["states"];
  if (!Array.isArray(states)) return { problem: `its "states" isn't a list` };
  for (const state of states) {
    if (
      !isRecord(state) ||
      !["id", "name", "source", "light", "dark"].every((field) => typeof state[field] === "string")
    ) {
      return { problem: "a state isn't an id, name, source, light and dark" };
    }
  }
  return json as unknown as CatalogManifest;
};

/** Which platform an app is for. */
export const platformOf = (app: string): Manifest["platform"] =>
  app.endsWith("-mac") ? "macos" : "ios";

/** Swift's escapes in a string literal: `\"`, `\\`, `\n`, `\t`, `\r`, `\0`, `\'` and `\u{…}`. */
export const unescapeSwift = (literal: string) =>
  literal.replace(/\\(u\{([0-9a-fA-F]{1,8})\}|.)/g, (_, escape: string, hex?: string) =>
    hex === undefined
      ? (({ n: "\n", t: "\t", r: "\r", "0": "\0" } as Record<string, string>)[escape] ?? escape)
      : String.fromCodePoint(Number.parseInt(hex, 16)),
  );

/**
 * Swift with its comments made spaces, so lines and offsets stay where they were. String literals
 * are kept as they are, so a `//` in one isn't taken for a comment.
 */
export const withoutSwiftComments = (source: string) =>
  source.replace(/"(?:[^"\\\n]|\\.)*"|\/\*[\s\S]*?\*\/|\/\/.*$/gm, (match) =>
    match.startsWith('"') ? match : match.replace(/[^\n]/g, " "),
  );

/**
 * Each state's line in a Swift file, by name: where its `CatalogState("…")` starts, as `#line`
 * gives it. A name written twice takes its first line.
 */
export const catalogStateLines = (source: string): ReadonlyMap<string, number> => {
  const lines = new Map<string, number>();
  const code = withoutSwiftComments(source);
  for (const match of code.matchAll(/\bCatalogState\(\s*"((?:[^"\\]|\\.)*)"/g)) {
    const name = unescapeSwift(match[1] ?? "");
    const line = code.slice(0, match.index).split("\n").length;
    if (!lines.has(name)) lines.set(name, line);
  }
  return lines;
};

/** What publishing needs of a commit, read with git. */
export interface CatalogInputs {
  /** Every catalog manifest, by its path. */
  readonly catalogs: ReadonlyArray<{ readonly path: string; readonly manifest: CatalogManifest }>;
  /** Each state's source file's text, by path; missing if the commit doesn't have it. */
  readonly sources: ReadonlyMap<string, string>;
  /** Each reference's variant, by path; missing if the commit doesn't have it. */
  readonly images: ReadonlyMap<string, Variant>;
}

/**
 * Every app's manifest from a commit's catalogs: their screens, in order, each state's light and
 * dark images, and its file and line. Says what it had to leave out: a catalog whose file is gone
 * (its manifest left behind) or a state without a reference.
 */
export const buildManifests = (
  key: string,
  commit: string,
  inputs: CatalogInputs,
): { readonly manifests: ReadonlyArray<Manifest>; readonly warnings: ReadonlyArray<string> } => {
  const warnings: string[] = [];
  const byApp = new Map<string, Snapshot[]>();
  const lineCache = new Map<string, ReadonlyMap<string, number>>();
  const linesOf = (source: string) => {
    const lines = lineCache.get(source) ?? catalogStateLines(inputs.sources.get(source) ?? "");
    lineCache.set(source, lines);
    return lines;
  };
  // A catalog file can hold several screens: their states are numbered one after another.
  const orders = new Map<string, number>();
  const sorted = inputs.catalogs.toSorted((a, b) =>
    a.path < b.path ? -1 : a.path > b.path ? 1 : 0,
  );
  for (const { path, manifest } of sorted) {
    const [module = "", file = ""] = manifest.catalog.split("/");
    const sources = new Set(manifest.states.map((state) => state.source));
    const gone = [...sources].filter((source) => !inputs.sources.has(source));
    if (gone.length > 0) {
      warnings.push(`${path} is left out: ${gone.join(", ")} doesn't exist. Delete it?`);
      continue;
    }
    const snapshots = byApp.get(manifest.app) ?? [];
    byApp.set(manifest.app, snapshots);
    for (const state of manifest.states) {
      const variants: { light?: Variant; dark?: Variant } = {};
      for (const appearance of ["light", "dark"] as const) {
        const variant = inputs.images.get(state[appearance]);
        if (variant === undefined) {
          warnings.push(
            `${manifest.screen}: "${state.name}" has no reference ${state[appearance]}.`,
          );
        } else {
          variants[appearance] = variant;
        }
      }
      if (variants.light === undefined && variants.dark === undefined) continue;
      const order = orders.get(`${manifest.app}/${manifest.catalog}`) ?? 0;
      orders.set(`${manifest.app}/${manifest.catalog}`, order + 1);
      snapshots.push({
        id: state.id,
        module,
        file,
        path: state.source,
        line: linesOf(state.source).get(state.name) ?? null,
        order,
        screen: manifest.screen,
        state: state.name,
        variants,
      });
    }
  }
  const manifests = [...byApp.entries()]
    .toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([app, snapshots]): Manifest => {
      const ids = new Set<string>();
      for (const { id } of snapshots) {
        if (ids.has(id)) warnings.push(`${app} has two states ${id}: Pixelbook shows one.`);
        ids.add(id);
      }
      return { version: 1, app, platform: platformOf(app), key, commit, snapshots };
    });
  return { manifests, warnings };
};

/**
 * A PNG's width and height, from its header, and scale, from its resolution (the pHYs chunk):
 * 72 dots per inch per point, so 144 for 2x, as SnapshotTesting writes them.
 */
export const pngInfo = (bytes: Buffer) => {
  let scale = 1;
  // Chunks follow the 8-byte signature: length, type, data, CRC.
  for (let offset = 8; offset + 8 <= bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString("latin1", offset + 4, offset + 8);
    if (type === "pHYs" && bytes[offset + 16] === 1) {
      // Pixels per meter.
      scale = Math.max(1, Math.round((bytes.readUInt32BE(offset + 8) * 0.0254) / 72));
    }
    if (type === "IDAT") break;
    offset += 12 + length;
  }
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), scale };
};

/**
 * How much smaller a thumbnail is than its image, in each dimension. Pixelbook's viewer
 * (`thumbnailDivisor` in `Web/pixelbook/src/lib/Snapshots.ts`) relies on it.
 */
const thumbnailDivisor = 4;

/** A PNG `thumbnailDivisor` times smaller. */
export const thumbnail = (png: Buffer) => encodePng(shrink(decodePng(png), thumbnailDivisor));

/** Runs `work` over `items`, `limit` at a time. */
const inParallel = async <A, B>(
  items: ReadonlyArray<A>,
  limit: number,
  work: (a: A) => Promise<B>,
) => {
  const results: B[] = [];
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await work(items[index] as A);
      }
    }),
  );
  return results;
};

const run = promisify(execFile);
const root = fileURLToPath(new URL("../../..", import.meta.url));

/** A blob's bytes, from git. */
const blob = async (sha: string) =>
  (
    await run("git", ["cat-file", "blob", sha], {
      cwd: root,
      encoding: "buffer",
      maxBuffer: 256 * 1024 * 1024,
    })
  ).stdout;

/**
 * A commit's catalogs, read from git rather than the working tree, so any fetched commit can be
 * published, and the working tree can change meanwhile. Each reference is read once, and kept in
 * `bytes` by its image's object key, for uploading.
 */
const readCommit = async (commit: string) => {
  const { stdout: tree } = await run(
    "git",
    ["ls-tree", "-r", "--full-tree", commit, "--", "LilPackage/Tests"],
    { cwd: root, maxBuffer: 64 * 1024 * 1024 },
  );
  // `<mode> blob <sha>\t<path>`.
  const blobs = new Map<string, string>();
  for (const line of tree.split("\n")) {
    const match = /^\d+ blob ([0-9a-f]+)\t(.+)$/.exec(line);
    if (match?.[1] !== undefined && match[2] !== undefined) blobs.set(match[2], match[1]);
  }
  const problems: string[] = [];
  const catalogs = (
    await inParallel([...blobs.keys()].filter(isCatalogManifest), 8, async (path) => {
      let json: unknown;
      try {
        json = JSON.parse((await blob(blobs.get(path) ?? "")).toString());
      } catch (error) {
        problems.push(`${path} is left out: it isn't JSON (${String(error)}).`);
        return [];
      }
      const parsed = parseCatalogManifest(json);
      if ("problem" in parsed) {
        problems.push(`${path} is left out: ${parsed.problem}.`);
        return [];
      }
      return [{ path, manifest: parsed }];
    })
  ).flat();
  const states = catalogs.flatMap(({ manifest }) => manifest.states);
  const sources = new Map<string, string>();
  for (const source of new Set(states.map((state) => state.source))) {
    const sha = blobs.get(source);
    if (sha !== undefined) sources.set(source, (await blob(sha)).toString());
  }
  const images = new Map<string, Variant>();
  const bytes = new Map<string, Buffer>();
  const references = [...new Set(states.flatMap((state) => [state.light, state.dark]))];
  await inParallel(references, 8, async (path) => {
    const sha = blobs.get(path);
    if (sha === undefined) return;
    const png = await blob(sha);
    // The PNG's bytes, not its pixels: a reference only changes when it's recorded again.
    const hash = createHash("sha256").update(png).digest("hex");
    const variant = {
      image: `images/${hash}.png`,
      thumbnail: `thumbnails/${hash}.png`,
      ...pngInfo(png),
    };
    images.set(path, variant);
    bytes.set(variant.image, png);
  });
  return { inputs: { catalogs, sources, images } satisfies CatalogInputs, bytes, problems };
};

/**
 * Points `refs/<ref>.json` at a commit, unless that would move it back: publishing an older
 * commit of a branch (a re-run of an earlier merge's job, say) leaves the newer commit's snapshots
 * in place. With `force`, it moves anyway: a push is the branch, even when it rewinds it.
 */
const pointRef = async (
  ref: string,
  commit: string,
  key: string,
  force: boolean,
  get: (objectKey: string) => Promise<string | undefined>,
  putIfChanged: (objectKey: string, value: unknown) => Promise<void>,
) => {
  const objectKey = `refs/${ref}.json`;
  const current = await get(objectKey);
  const previous = current === undefined ? undefined : (JSON.parse(current) as { commit?: string });
  if (!force && previous?.commit !== undefined && previous.commit !== commit) {
    // Exits 0 if `commit` is an ancestor of the ref's commit; it fails if that one isn't fetched.
    const behind = await run("git", ["merge-base", "--is-ancestor", commit, previous.commit], {
      cwd: root,
    }).then(
      () => true,
      () => false,
    );
    if (behind) {
      return console.log(`${ref} already points at ${previous.commit}, which is newer: kept.`);
    }
  }
  await putIfChanged(objectKey, { commit, key });
};

const argument = (name: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
};

/** A warning on a GitHub Actions run, or a line on stderr. */
const warn = (message: string) =>
  console.warn(process.env["GITHUB_ACTIONS"] === "true" ? `::warning::${message}` : message);

const main = async () => {
  const key = argument("key");
  const commit = argument("commit");
  const ref = argument("ref");
  const dryRun = process.argv.includes("--dry-run");
  const forceRef = process.argv.includes("--force-ref");
  if (key === undefined || commit === undefined) {
    throw new Error("usage: node scripts/pixelbook.ts --key <key> --commit <sha> [--ref <name>]");
  }
  const { token, account } = credentials();
  // PIXELBOOK_BUCKET: another bucket, to try this out.
  const bucket = process.env["PIXELBOOK_BUCKET"] ?? pixelbookBucketName;
  const bucketUrl = `https://api.cloudflare.com/client/v4/accounts/${account}/r2/buckets/${bucket}`;
  const authorization = { authorization: `Bearer ${token}` };
  const objectUrl = (objectKey: string) =>
    `${bucketUrl}/objects/${objectKey.split("/").map(encodeURIComponent).join("/")}`;

  /** Fetches, retrying when the network or Cloudflare's API briefly fails, or it rate limits. */
  const request = async (
    url: string,
    init: { method?: string; headers?: Record<string, string>; body?: Buffer | string } = {},
  ) => {
    for (let attempt = 1; ; attempt++) {
      const last = attempt === 5;
      try {
        const response = await fetch(url, {
          ...init,
          headers: { ...authorization, ...init.headers },
        });
        if ((response.status !== 429 && response.status < 500) || last) return response;
        await response.body?.cancel();
      } catch (error) {
        if (last) throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, 1000 * 2 ** attempt));
    }
  };
  /** The start of a failed response's body: Cloudflare's 5xx pages are long HTML. */
  const reason = async (response: Response) => (await response.text()).slice(0, 300);

  /** The object's text, or `undefined` if there's none. */
  const get = async (objectKey: string) => {
    const response = await request(objectUrl(objectKey));
    if (response.status === 404) return undefined;
    if (!response.ok) {
      throw new Error(`GET ${objectKey} answered ${response.status}: ${await reason(response)}`);
    }
    return response.text();
  };
  /** Objects uploaded, or that would be in a dry run. */
  let uploaded = 0;
  const put = async (objectKey: string, body: Buffer | string, contentType: string) => {
    if (dryRun) {
      uploaded++;
      return console.log(`Would upload ${objectKey}`);
    }
    const response = await request(objectUrl(objectKey), {
      method: "PUT",
      headers: { "content-type": contentType },
      body,
    });
    if (!response.ok) {
      throw new Error(`PUT ${objectKey} answered ${response.status}: ${await reason(response)}`);
    }
    uploaded++;
  };
  /** Every object key under `prefix`, a page of up to 1,000 at a time. */
  const list = async (prefix: string) => {
    const keys = new Set<string>();
    let cursor: string | undefined;
    do {
      const query = new URLSearchParams({ prefix, per_page: "1000" });
      if (cursor !== undefined) query.set("cursor", cursor);
      const response = await request(`${bucketUrl}/objects?${query.toString()}`);
      const json = (await response.json()) as {
        success?: boolean;
        result?: ReadonlyArray<{ key: string }>;
        result_info?: { cursor?: string; is_truncated?: boolean };
        errors?: unknown;
      };
      if (!response.ok || json.success !== true) {
        throw new Error(
          `Listing ${prefix} answered ${response.status}: ${JSON.stringify(json.errors)}`,
        );
      }
      for (const object of json.result ?? []) keys.add(object.key);
      cursor = json.result_info?.is_truncated === true ? json.result_info.cursor : undefined;
    } while (cursor !== undefined);
    return keys;
  };
  const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`;
  /** Writes a small JSON object unless it already holds `value`. */
  const putIfChanged = async (objectKey: string, value: unknown) => {
    if ((await get(objectKey)) !== json(value))
      await put(objectKey, json(value), "application/json");
  };

  const index = `snapshots/${key}/index.json`;
  if ((await get(index)) === undefined) {
    const { inputs, bytes, problems } = await readCommit(commit);
    const { manifests, warnings } = buildManifests(key, commit, inputs);
    for (const warning of [...problems, ...warnings]) warn(warning);
    const listed = await Promise.all([list("images/"), list("thumbnails/")]);
    const existing = new Set(listed.flatMap((keys) => [...keys]));
    const variants = new Map(
      manifests
        .flatMap(({ snapshots }) => snapshots)
        .flatMap(({ variants }) => [variants.light, variants.dark])
        .flatMap((variant) => (variant === undefined ? [] : [[variant.image, variant] as const])),
    );
    const png = (variant: Variant) => bytes.get(variant.image) ?? Buffer.alloc(0);
    const missing = [...variants.values()].filter(({ image }) => !existing.has(image));
    await inParallel(missing, 8, async (variant) => put(variant.image, png(variant), "image/png"));
    const missingThumbnails = [...variants.values()].filter(
      ({ thumbnail }) => !existing.has(thumbnail),
    );
    await inParallel(missingThumbnails, 8, async (variant) => {
      // A dry run only says what it would upload, so it doesn't make them.
      if (dryRun) return put(variant.thumbnail, "", "image/png");
      let small: Buffer;
      try {
        small = thumbnail(png(variant));
      } catch (error) {
        // A PNG it can't read (not 8-bit RGBA or RGB) gets itself as its thumbnail.
        warn(`Couldn't shrink ${variant.image}, so it's its own thumbnail: ${String(error)}`);
        small = png(variant);
      }
      return put(variant.thumbnail, small, "image/png");
    });
    for (const manifest of manifests) {
      await put(`snapshots/${key}/${manifest.app}.json`, json(manifest), "application/json");
    }
    // Last: a key with an index is complete.
    await put(
      index,
      json({
        key,
        commit,
        apps: manifests.map(({ app, platform, snapshots }) => ({
          app,
          platform,
          snapshots: snapshots.length,
        })),
      }),
      "application/json",
    );
    console.log(
      `${variants.size} images, ${missing.length} new, ${missingThumbnails.length} thumbnails; ` +
        `${manifests.length} manifests`,
    );
  } else {
    console.log(`Snapshots for ${key} are already published.`);
  }
  await putIfChanged(`commits/${commit}.json`, { key });
  if (ref !== undefined) await pointRef(ref, commit, key, forceRef, get, putIfChanged);
  const done = dryRun ? "would be uploaded" : "uploaded";
  console.log(uploaded === 0 ? "Nothing new to upload." : `${uploaded} objects ${done}.`);
};

if (import.meta.main) await main();
