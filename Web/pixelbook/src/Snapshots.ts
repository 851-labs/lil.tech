// Pixelbook's snapshots, published by `scripts/pixelbook publish` to a public R2 bucket that every
// stage reads. The types mirror what `Services/api/scripts/pixelbook.ts` writes.

/** The bucket's public domain (`pixelbookAssetsDomain` in `Services/api/src/Deployment.ts`). */
export const assetsUrl = "https://pixelbook-assets.lil.tech";

export type Scheme = "light" | "dark";
export const schemes: ReadonlyArray<Scheme> = ["light", "dark"];

export type Platform = "macos" | "ios";
export const platforms: ReadonlyArray<Platform> = ["macos", "ios"];

/** One rendered image of a state. */
export interface Variant {
  /** The object key of its image, under `images/`. */
  readonly image: string;
  /**
   * Its thumbnail's, under `thumbnails/`: a quarter of its width and height. Snapshots published
   * before thumbnails (851-2712) have none.
   */
  readonly thumbnail?: string;
  /** In pixels. */
  readonly width: number;
  readonly height: number;
  /** Pixels per point. */
  readonly scale: number;
}

/** A state of a screen: one preview, in each color scheme it was rendered in. */
export interface Snapshot {
  readonly id: string;
  readonly module: string;
  readonly file: string;
  readonly line: number | null;
  readonly screen: string;
  readonly state: string;
  readonly variants: Partial<Record<Scheme, Variant>>;
}

/** An app's snapshots for one key. */
export interface Manifest {
  readonly version: 1;
  /** E.g. `health-mac`. */
  readonly app: string;
  readonly platform: Platform;
  readonly key: string;
  readonly commit: string;
  readonly snapshots: ReadonlyArray<Snapshot>;
}

/** A commit's snapshots: every app's manifest. */
export interface Book {
  readonly key: string;
  readonly commit: string;
  readonly manifests: ReadonlyArray<Manifest>;
}

/** Which snapshots to show: a branch's latest (e.g. `main`), or a commit's, by its full SHA. */
export type Source = { readonly ref: string } | { readonly commit: string };

/** A full commit SHA, or else a branch. */
export const sourceOf = (value: string): Source =>
  /^[0-9a-f]{40}$/.test(value) ? { commit: value } : { ref: value };

// No parameter properties: `scripts/diff.ts` runs under Node, which only strips types.
export class NotPublished extends Error {
  readonly source: Source;

  constructor(source: Source) {
    super(
      "ref" in source
        ? `Nothing is published for ${source.ref} yet.`
        : `Nothing is published for ${source.commit.slice(0, 7)}.`,
    );
    this.source = source;
  }
}

const fetchJson = async <A>(path: string): Promise<A | undefined> => {
  // Branch names have slashes, which are kept; anything else is encoded.
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  const response = await fetch(`${assetsUrl}/${encoded}`);
  if (response.status === 404) return undefined;
  if (!response.ok) throw new Error(`${path} answered ${response.status}`);
  return (await response.json()) as A;
};

/** Loads a branch's or commit's snapshots. */
export const loadBook = async (source: Source): Promise<Book> => {
  const pointer =
    "ref" in source
      ? await fetchJson<{ commit: string; key: string }>(`refs/${source.ref}.json`)
      : await fetchJson<{ key: string }>(`commits/${source.commit}.json`).then((found) =>
          found === undefined ? undefined : { ...found, commit: source.commit },
        );
  if (pointer === undefined) throw new NotPublished(source);
  const index = await fetchJson<{ apps: ReadonlyArray<{ app: string }> }>(
    `snapshots/${pointer.key}/index.json`,
  );
  if (index === undefined) throw new NotPublished(source);
  const manifests = await Promise.all(
    index.apps.map(async ({ app }) => {
      const manifest = await fetchJson<Manifest>(`snapshots/${pointer.key}/${app}.json`);
      if (manifest === undefined) throw new Error(`${app}'s manifest is missing`);
      return manifest;
    }),
  );
  return { key: pointer.key, commit: pointer.commit, manifests };
};

/** The URL of a variant's image. */
export const imageUrl = (variant: Variant) => `${assetsUrl}/${variant.image}`;

/**
 * How much smaller a thumbnail is than its image, in each dimension, as publishing makes them
 * (`Services/api/scripts/pixelbook.ts`).
 */
const thumbnailDivisor = 4;

/**
 * Screen pixels per point that tiles are drawn at, rounded up to a quarter: a thumbnail holds
 * `scale / 4` pixels per point, so tiles only need to re-render when this crosses a quarter. Past
 * 1, every image (up to 4x) needs its original.
 */
export const tileDensity = (zoom: number, devicePixelRatio: number) =>
  Math.min(1, Math.ceil(zoom * devicePixelRatio * 4) / 4);

/**
 * The URL to show a variant at `density` screen pixels per point: its thumbnail while that holds
 * enough pixels, otherwise its image.
 */
export const tileImageUrl = (variant: Variant, density: number) =>
  variant.thumbnail !== undefined && density <= variant.scale / thumbnailDivisor
    ? `${assetsUrl}/${variant.thumbnail}`
    : imageUrl(variant);

/** Where a snapshot's preview is, on GitHub, at the commit it was rendered from. */
const repositoryUrl = "https://github.com/851-labs/lil.tech";

/** A commit on GitHub. */
export const commitUrl = (commit: string) => `${repositoryUrl}/commit/${commit}`;

/** What changed from `base` to `head`, on GitHub. */
export const compareUrl = (base: string, head: string) =>
  `${repositoryUrl}/compare/${base}...${head}`;

export const sourceUrl = (snapshot: Snapshot, commit: string) =>
  `${repositoryUrl}/blob/${commit}/LilPackage/Sources/${snapshot.module}/${snapshot.file}` +
  (snapshot.line === null ? "" : `#L${snapshot.line}`);

/** "health-mac" → "lil health for Mac". */
export const appName = (app: string, platform: Platform) => {
  const name = app.replace(/-(mac|iphone|ipad|ios)$/, "");
  return `lil ${name} for ${platform === "macos" ? "Mac" : "iPhone"}`;
};
