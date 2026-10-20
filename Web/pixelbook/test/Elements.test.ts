import { describe, expect, it } from "vite-plus/test";
import { flowNodes, gridNodes, labelExtent, withSteps } from "../src/lib/Elements.ts";
import type { FlowLayout, FlowNode } from "../src/lib/Flow.ts";
import type { Tile } from "../src/lib/Grid.ts";
import type { Snapshot } from "../src/lib/Snapshots.ts";

const tile = (id: string, x: number, y: number, width = 400, height = 300): Tile => {
  const variant = { image: `images/${id}.png`, width: width * 2, height: height * 2, scale: 2 };
  const snapshot: Snapshot = {
    id,
    module: "HealthMacApp",
    file: "SummaryPreviews.swift",
    line: 1,
    screen: "Summary",
    state: id,
    variants: { light: variant },
  };
  return {
    app: "health-mac",
    platform: "macos",
    snapshot,
    scheme: "light",
    variant,
    x,
    y,
    width,
    height,
  };
};

const screen = (key: string, x: number, tiles: ReadonlyArray<Tile>): FlowNode => ({
  key,
  title: key,
  tiles,
  x,
  y: 0,
  width: 400,
  height: 412,
});

describe("canvas nodes", () => {
  it("places the grid's labels and tiles with their sizes, so only those in view render", () => {
    const nodes = gridNodes({
      tiles: [tile("Loading", 80, 200)],
      labels: [{ kind: "app", text: "lil health", x: 80, y: 80 }],
    });
    expect(
      nodes.map(({ id, type, position, width, height, handles }) => ({
        id,
        type,
        position,
        width,
        height,
        handles,
      })),
    ).toEqual([
      {
        id: "label/app/80/80",
        type: "label",
        position: { x: 80, y: 80 },
        ...labelExtent,
        handles: [],
      },
      {
        id: "tile/health-mac/Loading/light",
        type: "tile",
        position: { x: 80, y: 200 },
        width: 400,
        height: 300,
        handles: [],
      },
    ]);
  });

  const first = screen("health-mac/summary", 0, [
    tile("Loading", 0, 0),
    tile("Big", 0, 0, 400, 900),
  ]);
  const second = screen("health-mac/account", 800, []);
  const layout: FlowLayout = {
    nodes: [first, second],
    edges: [
      {
        from: first.key,
        to: second.key,
        label: "Sign in",
        points: [
          { x: 400, y: 206 },
          { x: 800, y: 206 },
        ],
        labelAt: { x: 600, y: 206 },
      },
      {
        // Back to the first, around both screens.
        from: second.key,
        to: first.key,
        label: undefined,
        points: [
          { x: 1200, y: 206 },
          { x: 1200, y: -200 },
          { x: 0, y: -200 },
          { x: 0, y: 0 },
        ],
        labelAt: undefined,
      },
    ],
    labels: [],
    unlinked: [tile("Export", 0, 1000)],
    width: 1200,
    height: 1300,
  };

  it("draws the flowchart's routes as one node, as far as they reach, under the screens", () => {
    const [routes, summary, account, unlinked] = flowNodes(layout);
    // The routes and the first's label, with 40 points' margin.
    expect(routes).toMatchObject({
      id: "routes",
      type: "routes",
      position: { x: -40, y: -240 },
      width: 1280,
      height: 206 + 48 + 40 + 240,
      data: { edges: layout.edges },
    });
    // As tall as its largest state, which it can step to.
    expect(summary).toMatchObject({ type: "screen", zIndex: 0, width: 400, height: 112 + 900 });
    expect(account).toMatchObject({ id: "screen/health-mac/account" });
    expect(unlinked).toMatchObject({ type: "tile", position: { x: 0, y: 1000 } });
  });

  it("steps only the screens stepped, raising them", () => {
    const nodes = flowNodes(layout);
    const stepped = withSteps(nodes, new Map([[first.key, 1]]));
    expect(stepped[1]).toMatchObject({ zIndex: 1, data: { steps: 1 } });
    // The rest are the same objects, so React Flow skips them.
    expect(stepped.filter((node, index) => node !== nodes[index])).toEqual([stepped[1]]);
    expect(withSteps(nodes, new Map())).toBe(nodes);
  });
});
