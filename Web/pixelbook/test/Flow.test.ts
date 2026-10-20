import { describe, expect, it } from "vite-plus/test";
import {
  type FlowNode,
  layoutFlowchart,
  nodeExtent,
  nodeHeader,
  placeholder,
  unlinkedRowWidth,
} from "../src/lib/Flow.ts";
import type { Graph } from "../src/lib/Graph.ts";
import { noFilters, spacing } from "../src/lib/Grid.ts";
import type { Manifest, Snapshot } from "../src/lib/Snapshots.ts";

const snapshot = (file: string, state: string, line: number, dark = true): Snapshot => ({
  id: `${file}_${state}`,
  module: "HealthMacApp",
  file,
  line,
  screen: file.replace(/(Previews)?\.swift$/, ""),
  state,
  variants: {
    light: { image: `images/${file}-${state}-light.png`, width: 800, height: 600, scale: 2 },
    ...(dark
      ? { dark: { image: `images/${file}-${state}-dark.png`, width: 800, height: 600, scale: 2 } }
      : {}),
  },
});

const mac: Manifest = {
  version: 1,
  app: "health-mac",
  platform: "macos",
  key: "k",
  commit: "c",
  snapshots: [
    snapshot("SummaryPreviews.swift", "Loading", 20),
    snapshot("SummaryPreviews.swift", "Pinned", 10),
    snapshot("MetricPreviews.swift", "Steps", 5, false),
    snapshot("AccountPreviews.swift", "Export", 1),
  ],
};

const graph: Graph = {
  app: "health-mac",
  screens: [
    { id: "summary", screen: "HealthMacApp/SummaryPreviews.swift" },
    { id: "metric", screen: "HealthMacApp/MetricPreviews.swift", states: ["Steps"] },
  ],
  edges: [{ from: "summary", to: "metric", label: "Choose a metric" }],
};

describe("flowchart layout", () => {
  it("makes a node per graphed screen, with its states in source order", () => {
    const layout = layoutFlowchart([mac], [graph], noFilters);
    expect(layout.nodes.map((node) => node.key)).toEqual([
      "health-mac/summary",
      "health-mac/metric",
    ]);
    const [summary] = layout.nodes;
    expect(summary?.tiles.map((tile) => tile.snapshot.state)).toEqual(["Pinned", "Loading"]);
    // Light when both schemes show, and sized by the first state, below the header.
    expect(summary?.tiles[0]?.scheme).toBe("light");
    expect(summary).toMatchObject({ width: 400, height: nodeHeader + 300 });
    expect(layout.edges[0]).toMatchObject({ from: "health-mac/summary", to: "health-mac/metric" });
  });

  it("puts screens the graph leaves out in a row below", () => {
    const layout = layoutFlowchart([mac], [graph], noFilters);
    expect(layout.unlinked.map((tile) => tile.snapshot.state)).toEqual(["Export"]);
    const below = Math.max(...layout.nodes.map((node) => node.y + node.height));
    expect(layout.unlinked[0]!.y).toBeGreaterThan(below);
    expect(layout.labels.map((label) => label.text)).toContain("Not in the graph");
  });

  it("shows every screen as unlinked when an app has no graph", () => {
    const layout = layoutFlowchart([mac], [], noFilters);
    expect(layout.nodes).toEqual([]);
    expect(layout.unlinked).toHaveLength(3);
    expect(layout.labels.map((label) => label.text)).toContain("No graph yet");
  });

  it("uses the scheme the filters show, with a placeholder for screens without it", () => {
    const layout = layoutFlowchart([mac], [graph], { ...noFilters, schemes: ["dark"] });
    const [summary, metric] = layout.nodes;
    expect(summary?.tiles[0]?.scheme).toBe("dark");
    // The metric has no dark image: it stays, edges and all, as a placeholder.
    expect(metric).toMatchObject({ key: "health-mac/metric", tiles: [] });
    expect(metric?.height).toBe(nodeHeader + placeholder.height);
    expect(layout.edges).toHaveLength(1);
  });

  it("leaves out apps with nothing in the appearance", () => {
    const lightOnly: Manifest = {
      ...mac,
      app: "health-iphone",
      platform: "ios",
      snapshots: [snapshot("SignInView.swift", "Signed out", 1, false)],
    };
    const layout = layoutFlowchart([mac, lightOnly], [graph], { ...noFilters, schemes: ["dark"] });
    expect(
      layout.labels.filter((label) => label.kind === "app").map((label) => label.text),
    ).toEqual(["lil health for Mac"]);
  });

  it("wraps the rows of screens left out of the graph", () => {
    const many: Manifest = {
      ...mac,
      snapshots: Array.from({ length: 30 }, (_, index) =>
        snapshot(`Screen${String(index).padStart(2, "0")}Previews.swift`, "A", 1),
      ),
    };
    const layout = layoutFlowchart([many], [], noFilters);
    const right = Math.max(...layout.unlinked.map((tile) => tile.x + tile.width));
    expect(right).toBeLessThanOrEqual(spacing.margin + unlinkedRowWidth);
    expect(new Set(layout.unlinked.map((tile) => tile.y)).size).toBeGreaterThan(1);
  });

  it("reaches as far as a node's largest state", () => {
    const tile = (width: number, height: number) =>
      ({ width, height }) as unknown as FlowNode["tiles"][number];
    const node = {
      x: 10,
      y: 20,
      width: 400,
      height: nodeHeader + 800,
      tiles: [tile(400, 800), tile(400, 3000), tile(500, 600)],
    } as unknown as FlowNode;
    expect(nodeExtent(node)).toEqual({ x: 10, y: 20, width: 500, height: nodeHeader + 3000 });
  });
});
