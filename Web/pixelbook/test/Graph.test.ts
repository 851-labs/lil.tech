import { describe, expect, it } from "vite-plus/test";
import { checkGraphs, previewNames, scanPreviews } from "../scripts/graphs.ts";
import { layoutFlow } from "../src/lib/Flow.ts";
import { type Graph, graphProblems, parseGraph } from "../src/lib/Graph.ts";

const graph: Graph = {
  app: "health-mac",
  screens: [
    {
      id: "summary",
      screen: "HealthMacApp/SummaryViewPreviews.swift",
      states: ["Pinned", "Loading"],
    },
    { id: "metric", screen: "HealthMacApp/MetricDetailViewPreviews.swift" },
  ],
  edges: [{ from: "summary", to: "metric", label: "Choose a metric" }],
};

const previews = new Map([
  ["HealthMacApp/SummaryViewPreviews.swift", ["Pinned", "Loading"]],
  ["HealthMacApp/MetricDetailViewPreviews.swift", ["Steps, week"]],
]);

describe("graph files", () => {
  it("finds previews' names in Swift, over one line or several", () => {
    const source = `#Preview("Pinned") {}\n#Preview(\n  "Group",\n  traits: .x\n) {}\n#Preview("Say \\"hi\\"") {}`;
    expect(previewNames(source)).toEqual(["Pinned", "Group", 'Say "hi"']);
  });

  it("skips commented-out previews, and counts unnamed ones", () => {
    expect(
      previewNames('// #Preview("Old") {}\n/* #Preview("Older") {} */\n#Preview("New") {}'),
    ).toEqual(["New"]);
    expect(previewNames('#Preview {\n  Text("Hi")\n}')).toEqual([]);
    expect(previewNames('// #Preview("Old") {}\nstruct A {}')).toBeUndefined();
  });

  it("says what's wrong with a graph's shape", () => {
    expect(parseGraph(graph)).toEqual(graph);
    expect(parseGraph({ app: 1, screens: [{ id: "a" }], edges: [{ from: "a" }] })).toEqual({
      problems: [
        '"app" isn\'t a string.',
        "Screen 1's \"screen\" isn't a string.",
        'Edge 1 needs "from" and "to" strings.',
      ],
    });
  });

  it("catches a split file's previews that aren't on any screen", () => {
    const pinned = {
      id: "pinned",
      screen: "HealthMacApp/SummaryViewPreviews.swift",
      states: ["Pinned"],
    };
    const split: Graph = {
      app: "health-mac",
      screens: [
        pinned,
        { id: "editor", screen: "HealthMacApp/SummaryViewPreviews.swift", title: "E", states: [] },
      ],
      edges: [],
    };
    expect(graphProblems(split, previews)).toEqual([
      `HealthMacApp/SummaryViewPreviews.swift's "Loading" isn't on any screen.`,
    ]);
    // On one screen, `states` is just a selection.
    expect(graphProblems({ ...split, screens: [pinned] }, previews)).toEqual([]);
  });

  it("catches references to screens, states and nodes that don't exist", () => {
    expect(graphProblems(graph, previews)).toEqual([]);
    const broken: Graph = {
      ...graph,
      screens: [
        { id: "summary", screen: "HealthMacApp/SummaryViewPreviews.swift", states: ["Pined"] },
        { id: "summary", screen: "HealthMacApp/Gone.swift" },
      ],
    };
    expect(graphProblems(broken, previews)).toEqual([
      '"summary": HealthMacApp/SummaryViewPreviews.swift has no preview "Pined".',
      'Two screens are "summary".',
      '"summary": HealthMacApp/Gone.swift has no previews.',
      'An edge goes summary → metric, but "metric" isn\'t a screen.',
    ]);
  });

  it("checks the real graphs against the real previews", async () => {
    const problems = await checkGraphs(await scanPreviews());
    expect(Object.fromEntries(problems)).toEqual({});
  });
});

describe("flowchart layout", () => {
  const sizes = new Map([
    ["summary", { width: 400, height: 300 }],
    ["metric", { width: 400, height: 500 }],
  ]);

  it("lays screens out left to right, with each edge's route and label", () => {
    const { screens, edges } = layoutFlow(graph, sizes);
    const [summary, metric] = screens;
    expect(summary?.width).toBe(400);
    expect((metric?.x ?? 0) > (summary?.x ?? 0) + 400).toBe(true);
    expect(edges[0]?.label).toBe("Choose a metric");
    expect(edges[0]?.points.length).toBeGreaterThan(1);
    expect(edges[0]?.labelAt).toBeDefined();
  });

  it("moves nudged screens and draws their edges straight", () => {
    const plain = layoutFlow(graph, sizes);
    const nudged = layoutFlow(
      { ...graph, screens: [graph.screens[0]!, { ...graph.screens[1]!, nudge: [0, 200] }] },
      sizes,
    );
    expect(nudged.screens[1]?.y).toBe((plain.screens[1]?.y ?? 0) + 200);
    const [start, end] = nudged.edges[0]?.points ?? [];
    expect(start).toEqual({
      x: (nudged.screens[0]?.x ?? 0) + 400,
      y: (nudged.screens[0]?.y ?? 0) + 150,
    });
    expect(end).toEqual({ x: nudged.screens[1]?.x, y: (nudged.screens[1]?.y ?? 0) + 250 });
  });

  it("leaves out screens without a size, and their edges", () => {
    const { screens, edges } = layoutFlow(graph, new Map([["summary", { width: 1, height: 1 }]]));
    expect(screens.map((screen) => screen.id)).toEqual(["summary"]);
    expect(edges).toEqual([]);
  });
});
