import { describe, expect, it } from "vite-plus/test";
import { layoutFlowchart, nodeHeader } from "../src/Flow.ts";
import type { Graph } from "../src/Graph.ts";
import { noFilters } from "../src/Grid.ts";
import type { Manifest, Snapshot } from "../src/Snapshots.ts";

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

  it("uses the scheme the filters show, leaving out states without it", () => {
    const layout = layoutFlowchart([mac], [graph], { ...noFilters, schemes: ["dark"] });
    // The metric has no dark image, so it has no node, and its edge goes too.
    expect(layout.nodes.map((node) => node.key)).toEqual(["health-mac/summary"]);
    expect(layout.edges).toEqual([]);
    expect(layout.nodes[0]?.tiles[0]?.scheme).toBe("dark");
  });
});
