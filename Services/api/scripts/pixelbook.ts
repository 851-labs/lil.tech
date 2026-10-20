// Pixelbook (851-2696): publishes a render (`scripts/pixelbook render`) to R2, where every stage's
// Pixelbook reads it. Run through `scripts/pixelbook publish`, which works out the render's key
// and checks the tree is clean; from `Services/api`:
//   node scripts/pixelbook.ts --key <key> --commit <sha> [--render <dir>] [--ref <name> [--force-ref]]
//     [--dry-run]
// Without --render, it only writes the commit's and ref's pointers, and exits 3 if the key's
// snapshots aren't published yet: render them, then run it again with --render.
//
// The bucket (prod's, `pixelbookBucketName`) holds:
//   images/<sha256 of the pixels>.png  every image, once: an unchanged screen isn't uploaded again
//   thumbnails/<the same sha256>.png    the image at a quarter of its size, for zoomed-out views
//   snapshots/<key>/<app>.json          an app's manifest: its screens, states and variants
//   snapshots/<key>/index.json          the apps rendered for that key, written last
//   commits/<sha>.json                  which key a commit's snapshots are under
//   refs/<ref>.json                     the latest commit published from a branch, e.g. main
// A key names what the snapshots were rendered from: the trees of the code previews come from.
// Commits that share those trees (a branch and its squash merge, say) share snapshots.
//
// Credentials: see `scripts/cloudflare.ts`. PIXELBOOK_BUCKET uploads to another bucket.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import { pixelbookBucketName } from "../src/Deployment.ts";
import { credentials } from "./cloudflare.ts";

/** One rendered image of a state. */
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

/** A state of a screen: one preview, in each appearance it was rendered in. */
export interface Snapshot {
  /** Stable across renders: the preview's module, file and name, as SnapshotPreviews names it. */
  readonly id: string;
  readonly module: string;
  /** The file the preview is in, e.g. `SyncStatusViewPreviews.swift`. */
  readonly file: string;
  readonly line: number | null;
  /** The screen, from the file's name: `SyncStatusViewPreviews.swift` → "Sync Status". */
  readonly screen: string;
  /** The preview's name: the state. */
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

/** What SnapshotPreviews writes next to each image. */
interface Sidecar {
  readonly display_name?: string;
  readonly group?: string;
  readonly context?: { readonly preview?: { readonly line?: number } };
}

/** "SyncStatusViewPreviews.swift" → "Sync Status"; "AppView.swift" → "App". */
export const screenName = (file: string): string => {
  const stem = file
    .replace(/\.swift$/, "")
    .replace(/Previews$/, "")
    .replace(/Views?$/, "");
  const words = stem
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2");
  return words === "" ? file : words;
};

/** Which platform an app's folder holds. */
export const platformOf = (app: string): Manifest["platform"] =>
  app.endsWith("-mac") ? "macos" : "ios";

/** A rendered image, read from a render's folder. */
export interface RenderedImage {
  /** Its file name without `.png`, the same in every appearance's folder. */
  readonly name: string;
  readonly appearance: "light" | "dark";
  readonly sidecar: Sidecar;
  readonly variant: Variant;
}

/** An app's manifest from its rendered images, in a stable order. */
export const buildManifest = (
  app: string,
  key: string,
  commit: string,
  images: ReadonlyArray<RenderedImage>,
): Manifest => {
  const byName = new Map<string, RenderedImage[]>();
  for (const image of images) byName.set(image.name, [...(byName.get(image.name) ?? []), image]);
  const snapshots = [...byName.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, rendered]): Snapshot => {
      const sidecar: Sidecar = rendered[0]?.sidecar ?? {};
      const group = sidecar.group ?? "";
      const [module = "", file = ""] = group.split("/");
      const variants: { light?: Variant; dark?: Variant } = {};
      for (const image of rendered) variants[image.appearance] = image.variant;
      return {
        id: name,
        module,
        file,
        line: sidecar.context?.preview?.line ?? null,
        screen: screenName(file),
        state: sidecar.display_name ?? name,
        variants,
      };
    });
  return { version: 1, app, platform: platformOf(app), key, commit, snapshots };
};

const run = promisify(execFile);

/**
 * The SHA-256 of an image's pixels, as `sips` decodes them to BMP: PNG metadata differs between
 * renders of the same pixels, so it's not hashed.
 */
const pixelHash = async (png: string, scratch: string) => {
  const bmp = join(scratch, `${createHash("sha256").update(png).digest("hex")}.bmp`);
  await run("sips", ["-s", "format", "bmp", png, "--out", bmp]);
  const bytes = await readFile(bmp);
  await rm(bmp);
  return createHash("sha256").update(bytes).digest("hex");
};

/**
 * A PNG's width and height, from its header, and scale, from its resolution (the pHYs chunk):
 * SnapshotPreviews writes 72 dots per inch per point, so 144 for 2x.
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
 * (`thumbnailDivisor` in `Web/pixelbook/src/Snapshots.ts`) relies on it.
 */
const thumbnailDivisor = 4;

/** A copy of a variant's PNG, `thumbnailDivisor` times smaller, made with `sips`. */
const thumbnail = async (png: string, variant: Variant, scratch: string) => {
  const out = join(scratch, basename(variant.thumbnail));
  const thumbnailWidth = Math.max(1, Math.round(variant.width / thumbnailDivisor));
  await run("sips", ["--resampleWidth", String(thumbnailWidth), png, "--out", out]);
  const bytes = await readFile(out);
  await rm(out);
  return bytes;
};

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

/** Reads a render: `<render-dir>/<app>/<light|dark>/*.png` with their sidecars. */
const readRender = async (dir: string) => {
  const scratch = await mkdtemp(join(tmpdir(), "pixelbook-"));
  try {
    const apps = (await readdir(dir, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
    const read = await Promise.all(
      apps.map(async (app) => {
        const files: { appearance: "light" | "dark"; path: string }[] = [];
        for (const appearance of ["light", "dark"] as const) {
          const folder = join(dir, app, appearance);
          const names = await readdir(folder).catch(() => [] as string[]);
          for (const name of names.filter((n) => n.endsWith(".png"))) {
            files.push({ appearance, path: join(folder, name) });
          }
        }
        const images = await inParallel(files, 8, async ({ appearance, path }) => {
          // Only its header is needed: the bytes are read again to upload, if it's new.
          const bytes = await readFile(path);
          const sidecar = JSON.parse(
            await readFile(path.replace(/\.png$/, ".json"), "utf8").catch(() => "{}"),
          ) as Sidecar;
          const hash = await pixelHash(path, scratch);
          return {
            image: {
              name: basename(path, ".png"),
              appearance,
              sidecar,
              variant: {
                image: `images/${hash}.png`,
                thumbnail: `thumbnails/${hash}.png`,
                ...pngInfo(bytes),
              },
            } satisfies RenderedImage,
            path,
          };
        });
        return { app, images };
      }),
    );
    return read;
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
};

/**
 * Points `refs/<ref>.json` at a commit, unless that would move it back: publishing from an older
 * checkout of a branch (a stale main, say) leaves the newer commit's snapshots in place. With
 * `force`, it moves anyway: a push is the branch, even when it rewinds it.
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
    const behind = await run("git", ["merge-base", "--is-ancestor", commit, previous.commit]).then(
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

const main = async () => {
  const dir = argument("render");
  const key = argument("key");
  const commit = argument("commit");
  const ref = argument("ref");
  const dryRun = process.argv.includes("--dry-run");
  const forceRef = process.argv.includes("--force-ref");
  if (key === undefined || commit === undefined) {
    throw new Error("usage: node scripts/pixelbook.ts --key <key> --commit <sha> [--render <dir>]");
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
    if (dir === undefined) {
      console.log(`Snapshots for ${key} aren't published yet.`);
      process.exit(3);
    }
    const render = await readRender(dir);
    const listed = await Promise.all([list("images/"), list("thumbnails/")]);
    const existing = new Set(listed.flatMap((keys) => [...keys]));
    const images = new Map<string, { variant: Variant; path: string }>();
    for (const { images: appImages } of render) {
      for (const { image, path } of appImages) {
        images.set(image.variant.image, { variant: image.variant, path });
      }
    }
    const missing = [...images.values()].filter(({ variant }) => !existing.has(variant.image));
    await inParallel(missing, 8, async ({ variant, path }) =>
      put(variant.image, await readFile(path), "image/png"),
    );
    // Images published before thumbnails existed get theirs the next time they're rendered.
    const missingThumbnails = [...images.values()].filter(
      ({ variant }) => !existing.has(variant.thumbnail),
    );
    const scratch = await mkdtemp(join(tmpdir(), "pixelbook-"));
    try {
      await inParallel(missingThumbnails, 8, async ({ variant, path }) =>
        // A dry run only says what it would upload, so it doesn't make them.
        dryRun
          ? put(variant.thumbnail, "", "image/png")
          : put(variant.thumbnail, await thumbnail(path, variant, scratch), "image/png"),
      );
    } finally {
      await rm(scratch, { recursive: true, force: true });
    }
    const manifests = render.map(({ app, images: appImages }) =>
      buildManifest(
        app,
        key,
        commit,
        appImages.map(({ image }) => image),
      ),
    );
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
      `${images.size} images, ${missing.length} new, ${missingThumbnails.length} thumbnails; ` +
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
