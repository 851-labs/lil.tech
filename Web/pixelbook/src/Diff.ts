// What changed between two commits' snapshots: images are named by a hash of their pixels, so a
// snapshot changed exactly when an appearance's image did. Added and removed snapshots are
// matched by ID (module, file and preview name), so a renamed preview shows as both.
import {
  byText,
  type ChangeLabel,
  type Filters,
  type Label,
  shows,
  spacing,
  type Tile,
} from "./Grid.ts";
import {
  appName,
  type Book,
  type Platform,
  type Scheme,
  schemes,
  type Snapshot,
} from "./Snapshots.ts";

export type ChangeKind = "changed" | "added" | "removed";

/** A snapshot that differs between the base and the head. */
export interface SnapshotChange {
  readonly app: string;
  readonly platform: Platform;
  readonly kind: ChangeKind;
  readonly before: Snapshot | undefined;
  readonly after: Snapshot | undefined;
  /** The appearances whose images differ. */
  readonly schemes: ReadonlyArray<Scheme>;
}

const snapshotOf = (change: SnapshotChange): Snapshot => {
  const snapshot = change.after ?? change.before;
  if (snapshot === undefined) throw new Error("A change needs a side");
  return snapshot;
};

/** Every snapshot that differs between `base` and `head`, by app, screen and source order. */
export const diffBooks = (base: Book, head: Book): ReadonlyArray<SnapshotChange> => {
  const changes: SnapshotChange[] = [];
  const apps = new Map(
    [...base.manifests, ...head.manifests].map((manifest) => [manifest.app, manifest.platform]),
  );
  for (const [app, platform] of apps) {
    const before = new Map(
      base.manifests.find((m) => m.app === app)?.snapshots.map((s) => [s.id, s]) ?? [],
    );
    const after = new Map(
      head.manifests.find((m) => m.app === app)?.snapshots.map((s) => [s.id, s]) ?? [],
    );
    for (const [id, snapshot] of after) {
      const old = before.get(id);
      if (old === undefined) {
        const present = schemes.filter((scheme) => snapshot.variants[scheme] !== undefined);
        changes.push({
          app,
          platform,
          kind: "added",
          before: undefined,
          after: snapshot,
          schemes: present,
        });
        continue;
      }
      const differing = schemes.filter(
        (scheme) => old.variants[scheme]?.image !== snapshot.variants[scheme]?.image,
      );
      if (differing.length > 0) {
        changes.push({
          app,
          platform,
          kind: "changed",
          before: old,
          after: snapshot,
          schemes: differing,
        });
      }
    }
    for (const [id, snapshot] of before) {
      if (after.has(id)) continue;
      const present = schemes.filter((scheme) => snapshot.variants[scheme] !== undefined);
      changes.push({
        app,
        platform,
        kind: "removed",
        before: snapshot,
        after: undefined,
        schemes: present,
      });
    }
  }
  return changes.toSorted((a, b) => {
    const x = snapshotOf(a);
    const y = snapshotOf(b);
    return (
      byText(a.app, b.app) ||
      byText(x.screen, y.screen) ||
      (x.line ?? 0) - (y.line ?? 0) ||
      byText(x.state, y.state)
    );
  });
};

/** A comparison's size, for the PR comment: snapshots, and the screens they're on. */
export const summarize = (changes: ReadonlyArray<SnapshotChange>) => {
  const count = (kind: ChangeKind) => changes.filter((change) => change.kind === kind).length;
  const screens = new Set(changes.map((change) => `${change.app}/${snapshotOf(change).screen}`));
  return {
    changed: count("changed"),
    added: count("added"),
    removed: count("removed"),
    screens: screens.size,
  };
};

/** "2 changed, 1 new on 3 screens", or "No changes": the page's and the PR comment's wording. */
export const describeChanges = (summary: ReturnType<typeof summarize>) => {
  const parts = [
    summary.changed > 0 ? `${summary.changed} changed` : undefined,
    summary.added > 0 ? `${summary.added} new` : undefined,
    summary.removed > 0 ? `${summary.removed} removed` : undefined,
  ].filter((part) => part !== undefined);
  if (parts.length === 0) return "No changes";
  const screens = `${summary.screens} ${summary.screens === 1 ? "screen" : "screens"}`;
  return `${parts.join(", ")} on ${screens}`;
};

/**
 * Lays a comparison out like the grid: an app per section, a screen per row. A changed state shows
 * each differing appearance before and after; an added or removed one shows its own side.
 */
export const layoutDiff = (changes: ReadonlyArray<SnapshotChange>, filters: Filters) => {
  const tiles: Tile[] = [];
  const labels: Label[] = [];
  let y = spacing.margin;
  let width = 0;
  const shown = changes
    .filter((change) => shows(filters.apps, change.app))
    .filter((change) => shows(filters.platforms, change.platform));
  for (const [app, appChanges] of Map.groupBy(shown, (change) => change.app)) {
    const rows = [...Map.groupBy(appChanges, (change) => snapshotOf(change).screen)].flatMap(
      ([screen, screenChanges]) => {
        const row = layoutChanges(screenChanges, filters);
        return row.tiles.length === 0 ? [] : [{ screen, ...row }];
      },
    );
    if (rows.length === 0) continue;
    if (labels.length > 0) y += spacing.app;
    const platform = appChanges[0]?.platform ?? "ios";
    labels.push({ kind: "app", text: appName(app, platform), x: spacing.margin, y });
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

/** A screen's changes in a row, from x = 0 and y = 0. */
const layoutChanges = (changes: ReadonlyArray<SnapshotChange>, filters: Filters) => {
  const tiles: Tile[] = [];
  let x = 0;
  let height = 0;
  const place = (
    change: SnapshotChange,
    snapshot: Snapshot,
    scheme: Scheme,
    label: ChangeLabel,
    other: Snapshot | undefined,
    gap: number,
  ) => {
    const variant = snapshot.variants[scheme];
    if (variant === undefined) return;
    if (tiles.length > 0) x += gap;
    const tileWidth = variant.width / variant.scale;
    const tileHeight = variant.height / variant.scale;
    const otherVariant = other?.variants[scheme];
    tiles.push({
      app: change.app,
      platform: change.platform,
      snapshot,
      scheme,
      variant,
      x,
      y: 0,
      width: tileWidth,
      height: tileHeight,
      change: otherVariant === undefined ? { label } : { label, other: otherVariant },
    });
    x += tileWidth;
    height = Math.max(height, tileHeight);
  };
  for (const change of changes) {
    for (const scheme of change.schemes.filter((scheme) => shows(filters.schemes, scheme))) {
      // Per appearance: a changed snapshot can gain or lose one.
      const before = change.before?.variants[scheme] === undefined ? undefined : change.before;
      const after = change.after?.variants[scheme] === undefined ? undefined : change.after;
      if (before !== undefined && after !== undefined) {
        place(change, before, scheme, "Before", after, spacing.tile);
        place(change, after, scheme, "After", before, spacing.scheme);
      } else if (after !== undefined) {
        place(change, after, scheme, "New", undefined, spacing.tile);
      } else if (before !== undefined) {
        place(change, before, scheme, "Removed", undefined, spacing.tile);
      }
    }
  }
  return { tiles, width: x, height };
};
