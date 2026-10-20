import { describe, expect, it } from "vite-plus/test";
import type { FlowLayout, FlowNode } from "../src/lib/Flow.ts";
import type { ChangeLabel, Tile } from "../src/lib/Grid.ts";
import { flowLayers, gridLayers, layerOf, searchLayers } from "../src/lib/Layers.ts";
import type { Scheme, Snapshot } from "../src/lib/Snapshots.ts";

const tile = (
  app: string,
  screen: string,
  state: string,
  scheme: Scheme = "light",
  change?: ChangeLabel,
): Tile => {
  const variant = { image: `images/${screen}-${state}.png`, width: 800, height: 600, scale: 2 };
  const snapshot: Snapshot = {
    id: `${screen}_${state}`,
    module: "HealthMacApp",
    file: `${screen}Previews.swift`,
    line: 1,
    screen,
    state,
    variants: { [scheme]: variant },
  };
  return {
    app,
    platform: app.endsWith("mac") ? "macos" : "ios",
    snapshot,
    scheme,
    variant,
    x: 0,
    y: 0,
    width: 400,
    height: 300,
    ...(change === undefined ? {} : { change: { label: change } }),
  };
};

const names = (apps: ReturnType<typeof gridLayers>) =>
  apps.map((app) => [
    app.name,
    app.screens.map((screen) => [
      screen.name,
      screen.states.map((state) =>
        [state.name, state.detail, state.badge].filter((part) => part !== undefined).join(" "),
      ),
    ]),
  ]);

describe("layers", () => {
  it("lists the grid's tiles by app and screen, in its order", () => {
    const layers = gridLayers([
      tile("health-mac", "Summary", "Loading"),
      tile("health-mac", "Summary", "Loading", "dark"),
      tile("health-mac", "Account", "Export"),
      tile("health-iphone", "Sync Status", "Checking"),
    ]);
    expect(names(layers)).toEqual([
      [
        "lil health for Mac",
        [
          ["Summary", ["Loading Light", "Loading Dark"]],
          ["Account", ["Export Light"]],
        ],
      ],
      ["lil health for iPhone", [["Sync Status", ["Checking Light"]]]],
    ]);
  });

  it("makes a change's before and after one row, choosing the after", () => {
    const before = tile("health-mac", "Summary", "Pinned", "dark", "Before");
    const after = tile("health-mac", "Summary", "Pinned", "dark", "After");
    const layers = gridLayers([
      before,
      after,
      tile("health-mac", "Sleep", "Night", "light", "New"),
    ]);
    expect(names(layers)).toEqual([
      [
        "lil health for Mac",
        [
          ["Summary", ["Pinned Dark Changed"]],
          ["Sleep", ["Night Light New"]],
        ],
      ],
    ]);
    const pinned = layers[0]?.screens[0]?.states[0];
    expect(pinned?.tile).toBe(after);
    // Selecting either tile on the canvas finds the row.
    expect(layerOf(layers, "health-mac/Summary_Pinned/dark/Before")?.state).toBe(pinned?.key);
  });

  it("lists the flowchart's screens with their states, stepping to them, then those not in a graph", () => {
    const node: FlowNode = {
      key: "health-mac/summary",
      title: "Summary",
      tiles: [tile("health-mac", "Summary", "Loading"), tile("health-mac", "Summary", "Loaded")],
      x: 0,
      y: 0,
      width: 400,
      height: 412,
    };
    const layout: FlowLayout = {
      nodes: [node, { ...node, key: "health-mac/empty", title: "Empty", tiles: [] }],
      edges: [],
      labels: [],
      unlinked: [tile("health-mac", "Account", "Export")],
      width: 1000,
      height: 1000,
    };
    const layers = flowLayers(layout);
    // The screen without snapshots has nothing to choose.
    expect(names(layers)).toEqual([
      [
        "lil health for Mac",
        [
          ["Summary", ["Loading", "Loaded"]],
          ["Account", ["Export"]],
        ],
      ],
    ]);
    expect(layers[0]?.screens[0]?.states[1]?.step).toEqual({ key: "health-mac/summary", index: 1 });
    expect(layers[0]?.screens[1]?.states[0]?.step).toBeUndefined();
  });

  it("orders the flowchart's apps as the canvas does, even one with no graph", () => {
    const graphed: FlowNode = {
      key: "health-mac/summary",
      title: "Summary",
      tiles: [tile("health-mac", "Summary", "Loading")],
      x: 0,
      y: 900,
      width: 400,
      height: 412,
    };
    // The iPhone app has no graph, and is above the Mac app on the canvas.
    const unlinked = { ...tile("health-iphone", "Sync Status", "Checking"), y: 200 };
    const layout: FlowLayout = {
      nodes: [graphed],
      edges: [],
      labels: [],
      unlinked: [unlinked],
      width: 1000,
      height: 1400,
    };
    expect(flowLayers(layout).map((app) => app.name)).toEqual([
      "lil health for iPhone",
      "lil health for Mac",
    ]);
  });

  it("searches screen and state names, keeping a matching screen's states", () => {
    const layers = gridLayers([
      tile("health-mac", "Summary", "Loading"),
      tile("health-mac", "Summary", "Pinned"),
      tile("health-mac", "Account", "Export"),
      tile("health-iphone", "Sync Status", "Loading"),
    ]);
    expect(names(searchLayers(layers, "summ"))).toEqual([
      ["lil health for Mac", [["Summary", ["Loading Light", "Pinned Light"]]]],
    ]);
    expect(names(searchLayers(layers, " LOADING "))).toEqual([
      ["lil health for Mac", [["Summary", ["Loading Light"]]]],
      ["lil health for iPhone", [["Sync Status", ["Loading Light"]]]],
    ]);
    expect(searchLayers(layers, "nothing")).toEqual([]);
    expect(searchLayers(layers, "")).toEqual(layers);
  });
});
