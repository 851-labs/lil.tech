// Grid mode: lays a commit's snapshots out on the canvas, an app per section and a screen per row,
// each state's color schemes side by side. Positions are in points, the canvas's units.
import type { Manifest, Platform, Scheme, Snapshot, Variant } from "./Snapshots.ts";
import { appName, schemes } from "./Snapshots.ts";

/** Which snapshots to show. An empty list shows all of that kind. */
export interface Filters {
  readonly apps: ReadonlyArray<string>;
  readonly platforms: ReadonlyArray<Platform>;
  readonly schemes: ReadonlyArray<Scheme>;
}

export const noFilters: Filters = { apps: [], platforms: [], schemes: [] };

export const shows = <A>(chosen: ReadonlyArray<A>, value: A) =>
  chosen.length === 0 || chosen.includes(value);

/** What an image is in a comparison: one side of a change, or added, or removed. */
export type ChangeLabel = "Before" | "After" | "New" | "Removed";

/** A snapshot in one color scheme, placed on the canvas. */
export interface Tile {
  readonly app: string;
  readonly platform: Platform;
  readonly snapshot: Snapshot;
  readonly scheme: Scheme;
  readonly variant: Variant;
  readonly x: number;
  readonly y: number;
  /** In points: the image's pixels over its scale. */
  readonly width: number;
  readonly height: number;
  /** In a comparison (`Diff.ts`): what this image is, e.g. "Before", and the other side's. */
  readonly change?: { readonly label: ChangeLabel; readonly other?: Variant };
}

/** A label on the canvas: an app's title or a screen's name. */
export interface Label {
  readonly kind: "app" | "screen" | "caption";
  readonly text: string;
  readonly x: number;
  readonly y: number;
}

export interface Layout {
  readonly tiles: ReadonlyArray<Tile>;
  readonly labels: ReadonlyArray<Label>;
  readonly width: number;
  readonly height: number;
}

/** Spacing, in points. */
export const spacing = {
  /** Around everything. */
  margin: 80,
  /** Between tiles in a row. */
  tile: 24,
  /** Between a state's color schemes, closer than between states. */
  scheme: 8,
  /** The height of a screen's label, above its row. */
  screenLabel: 88,
  /** Between rows. */
  row: 96,
  /** The height of an app's title, above its screens. */
  appLabel: 160,
  /** Between apps. */
  app: 240,
};

export const byText = (a: string, b: string) => a.localeCompare(b, "en");

/** A screen's states in their catalog's order, or previews in the order they're written. */
export const sourceOrder = (a: Snapshot, b: Snapshot) =>
  (a.order !== undefined && b.order !== undefined ? a.order - b.order : 0) ||
  (a.line ?? 0) - (b.line ?? 0) ||
  byText(a.state, b.state);

/** A row of tiles, placed from x = 0 and y = 0. */
export const layoutRow = (
  manifest: Manifest,
  states: ReadonlyArray<Snapshot>,
  shownSchemes: ReadonlyArray<Scheme>,
) => {
  const tiles: Tile[] = [];
  let x = 0;
  let height = 0;
  for (const snapshot of states) {
    let placed = 0;
    for (const scheme of shownSchemes) {
      const variant = snapshot.variants[scheme];
      if (variant === undefined) continue;
      if (placed > 0) x += spacing.scheme;
      else if (tiles.length > 0) x += spacing.tile;
      const width = variant.width / variant.scale;
      const tileHeight = variant.height / variant.scale;
      const { app, platform } = manifest;
      tiles.push({ app, platform, snapshot, scheme, variant, x, y: 0, width, height: tileHeight });
      x += width;
      height = Math.max(height, tileHeight);
      placed++;
    }
  }
  return { tiles, width: x, height };
};

/**
 * Lays out the snapshots `filters` shows. Apps and screens are alphabetical, states in source
 * order. Screens and apps with nothing to show are left out.
 */
export const layoutGrid = (manifests: ReadonlyArray<Manifest>, filters: Filters): Layout => {
  const tiles: Tile[] = [];
  const labels: Label[] = [];
  let y = spacing.margin;
  let width = 0;
  const shownSchemes = schemes.filter((scheme) => shows(filters.schemes, scheme));
  const shownManifests = manifests
    .filter((manifest) => shows(filters.apps, manifest.app))
    .filter((manifest) => shows(filters.platforms, manifest.platform))
    .toSorted((a, b) => byText(a.app, b.app));
  for (const manifest of shownManifests) {
    const screens = Map.groupBy(manifest.snapshots, (snapshot) => snapshot.screen);
    const rows = [...screens.keys()]
      .toSorted(byText)
      .map((screen) => {
        const states = (screens.get(screen) ?? []).toSorted(sourceOrder);
        return { screen, ...layoutRow(manifest, states, shownSchemes) };
      })
      .filter((row) => row.tiles.length > 0);
    if (rows.length === 0) continue;
    if (labels.length > 0) y += spacing.app;
    const text = appName(manifest.app, manifest.platform);
    labels.push({ kind: "app", text, x: spacing.margin, y });
    y += spacing.appLabel;
    for (const [index, row] of rows.entries()) {
      if (index > 0) y += spacing.row;
      labels.push({ kind: "screen", text: row.screen, x: spacing.margin, y });
      y += spacing.screenLabel;
      for (const tile of row.tiles) tiles.push({ ...tile, x: spacing.margin + tile.x, y });
      width = Math.max(width, spacing.margin + row.width);
      y += row.height;
    }
  }
  return { tiles, labels, width: width + spacing.margin, height: y + spacing.margin };
};

/** A tile's stable key, for React and for links to it. */
export const tileId = (tile: Pick<Tile, "app" | "snapshot" | "scheme" | "change">) =>
  `${tile.app}/${tile.snapshot.id}/${tile.scheme}` +
  (tile.change === undefined ? "" : `/${tile.change.label}`);
