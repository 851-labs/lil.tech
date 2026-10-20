// The sidebar's layers list (851-2763): what's on the canvas, as apps, their screens and each
// screen's states, in the canvas's order, built from the same layouts.
import type { FlowLayout } from "./Flow.ts";
import { type ChangeLabel, type Tile, tileId } from "./Grid.ts";
import { appName, schemeNames } from "./Snapshots.ts";

/** In a comparison: how a state changed. */
export type Badge = "Changed" | "New" | "Removed";

/** The canvas's label whose color a badge shares: a change's is its after's. */
export const badgeLabel: Record<Badge, ChangeLabel> = {
  Changed: "After",
  New: "New",
  Removed: "Removed",
};

/** A state of a screen: choosing it selects `tile`. */
export interface LayerState {
  /** Unique in the list. */
  readonly key: string;
  readonly name: string;
  /** Told apart from the screen's other rows: its appearance, in the grid. */
  readonly detail: string | undefined;
  readonly tile: Tile;
  /** The tiles it stands for, by ID, which select it: a change's before and after. */
  readonly ids: ReadonlyArray<string>;
  readonly badge: Badge | undefined;
  /** On the flowchart: the screen's key, and how far to step it to show this state. */
  readonly step: { readonly key: string; readonly index: number } | undefined;
}

export interface LayerScreen {
  readonly key: string;
  readonly name: string;
  readonly states: ReadonlyArray<LayerState>;
}

export interface LayerApp {
  readonly key: string;
  readonly name: string;
  readonly screens: ReadonlyArray<LayerScreen>;
}

/** Groups `items` by `key`, in the order each key first appears. */
const groupInOrder = <A>(items: ReadonlyArray<A>, key: (item: A) => string) => [
  ...Map.groupBy(items, key),
];

/**
 * The grid's, or a comparison's: a row per tile, by app and screen. A change's before and after
 * are one row, choosing the after, with its badge.
 */
export const gridLayers = (tiles: ReadonlyArray<Tile>): LayerApp[] =>
  groupInOrder(tiles, (tile) => tile.app).map(([app, appTiles]) => ({
    key: app,
    name: appName(app, appTiles[0]?.platform ?? "ios"),
    screens: groupInOrder(appTiles, (tile) => tile.snapshot.screen).map(
      ([screen, screenTiles]) => ({
        key: `${app}/${screen}`,
        name: screen,
        // A change's two tiles are one row.
        states: groupInOrder(screenTiles, (tile) => `${tile.snapshot.id}/${tile.scheme}`).flatMap(
          ([key, rowTiles]) => {
            const tile = rowTiles.find((t) => t.change?.label !== "Before") ?? rowTiles[0];
            if (tile === undefined) return [];
            const label = tile.change?.label;
            return [
              {
                key: `${app}/${key}`,
                name: tile.snapshot.state,
                detail: schemeNames[tile.scheme],
                tile,
                ids: rowTiles.map(tileId),
                badge:
                  label === undefined
                    ? undefined
                    : label === "New" || label === "Removed"
                      ? label
                      : "Changed",
                step: undefined,
              },
            ];
          },
        ),
      }),
    ),
  }));

/**
 * The flowchart's: each app's screens in its graph with their states, then those not in it. Apps
 * are in the canvas's order, top to bottom.
 */
export const flowLayers = (layout: FlowLayout): LayerApp[] => {
  const screens = [
    ...layout.nodes.map((node) => ({
      app: node.tiles[0]?.app,
      platform: node.tiles[0]?.platform,
      y: node.y,
      key: `graph/${node.key}`,
      name: node.title,
      states: node.tiles.map((tile, index) => ({ tile, step: { key: node.key, index } })),
    })),
    ...layout.unlinked.map((tile) => ({
      app: tile.app,
      platform: tile.platform,
      y: tile.y,
      key: `unlinked/${tile.app}/${tile.snapshot.screen}`,
      name: tile.snapshot.screen,
      states: [{ tile, step: undefined }],
    })),
  ];
  // A screen the graph names without snapshots has nothing to select.
  const shown = screens.filter((screen) => screen.states.length > 0);
  const top = (group: ReadonlyArray<{ readonly y: number }>) =>
    Math.min(...group.map((screen) => screen.y));
  const apps = groupInOrder(shown, (screen) => screen.app ?? "").toSorted(
    ([, a], [, b]) => top(a) - top(b),
  );
  return apps.map(([app, appScreens]) => ({
    key: app,
    name: appName(app, appScreens[0]?.platform ?? "ios"),
    screens: appScreens.map((screen) => ({
      key: screen.key,
      name: screen.name,
      states: screen.states.map(({ tile, step }) => ({
        key: `${screen.key}/${tileId(tile)}`,
        name: tile.snapshot.state,
        detail: undefined,
        tile,
        ids: [tileId(tile)],
        badge: undefined,
        step,
      })),
    })),
  }));
};

/**
 * The layers whose screen or state names contain `query`, ignoring case: a screen that matches
 * keeps all its states. All of them for an empty query.
 */
export const searchLayers = (apps: ReadonlyArray<LayerApp>, query: string): LayerApp[] => {
  const wanted = query.trim().toLowerCase();
  if (wanted === "") return [...apps];
  const matches = (name: string) => name.toLowerCase().includes(wanted);
  return apps.flatMap((app) => {
    const screens = app.screens.flatMap((screen) => {
      if (matches(screen.name)) return [screen];
      const states = screen.states.filter((state) => matches(state.name));
      return states.length === 0 ? [] : [{ ...screen, states }];
    });
    return screens.length === 0 ? [] : [{ ...app, screens }];
  });
};

/** Where the tile with this ID is in the list: its app's and screen's keys. */
export const layerOf = (apps: ReadonlyArray<LayerApp>, id: string | undefined) => {
  if (id === undefined) return undefined;
  for (const app of apps)
    for (const screen of app.screens)
      for (const state of screen.states)
        if (state.ids.includes(id)) return { app: app.key, screen: screen.key, state: state.key };
  return undefined;
};
