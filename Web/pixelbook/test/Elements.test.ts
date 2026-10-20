import { describe, expect, it } from "vite-plus/test";
import { flowElements, gridElements, labelExtent } from "../src/Elements.ts";
import type { FlowLayout, FlowNode } from "../src/Flow.ts";
import type { Tile } from "../src/Grid.ts";
import type { Snapshot } from "../src/Snapshots.ts";

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

describe("canvas elements", () => {
  it("places the grid's labels and tiles with their sizes, so only those in view render", () => {
    const { nodes, edges } = gridElements({
      tiles: [tile("Loading", 80, 200)],
      labels: [{ kind: "app", text: "lil health", x: 80, y: 80 }],
    });
    expect(edges).toEqual([]);
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

  it("joins the flowchart's screens with its routes, and raises a stepped screen", () => {
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
      ],
      labels: [],
      unlinked: [tile("Export", 0, 1000)],
      width: 1200,
      height: 1300,
    };
    const { nodes, edges } = flowElements(layout, new Map([[first.key, 1]]));
    expect(edges).toEqual([
      {
        id: "route/health-mac/summary/health-mac/account/0",
        type: "route",
        source: "screen/health-mac/summary",
        target: "screen/health-mac/account",
        data: { edge: layout.edges[0] },
      },
    ]);
    const [summary, account, unlinked] = nodes;
    // As tall as its largest state, which it can step to.
    expect(summary).toMatchObject({ type: "screen", zIndex: 1, width: 400, height: 112 + 900 });
    expect(summary?.handles?.map((handle) => [handle.type, handle.x, handle.y])).toEqual([
      ["target", 0, 206],
      ["source", 400, 206],
    ]);
    expect(account).toMatchObject({ id: "screen/health-mac/account", zIndex: 0 });
    expect(unlinked).toMatchObject({ type: "tile", position: { x: 0, y: 1000 } });
  });
});
