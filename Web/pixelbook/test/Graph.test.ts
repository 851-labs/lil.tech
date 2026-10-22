import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import {
  catalogStateNames,
  checkGraphs,
  manifestProblems,
  previewNames,
  scanCatalogs,
  scanScreens,
} from "../scripts/graphs.ts";
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

  it("finds a catalog's state names, outside comments and strings", () => {
    const source = [
      "StateCatalog(",
      '  "Metric Detail", width: 760, minHeight: 820,',
      "  states: [",
      '    CatalogState("Steps, week") { a },',
      '    // CatalogState("Old") { b },',
      "    CatalogState(",
      '      "Say \\"hi\\" \\u{2019}", minHeight: 400',
      "    ) { c },",
      '    CatalogState("Link") { Text("https://lil.tech CatalogState(\\"No\\")") },',
      '    CatalogState("After the link") { d },',
      "  ])",
    ].join("\n");
    expect(catalogStateNames(source)).toEqual([
      "Steps, week",
      'Say "hi" \u2019',
      "Link",
      "After the link",
    ]);
    expect(catalogStateNames("struct A {}")).toEqual([]);
  });

  describe("catalog manifests", () => {
    const folder = "LilPackage/Tests/Mac/Catalogs/LilAuth";
    const manifest = (app: string, screen: string, names: ReadonlyArray<string>) => ({
      app,
      screen,
      catalog: "LilAuth/SignInCatalog.swift",
      states: names.map((name) => ({
        id: name,
        name,
        source: `${folder}/SignInCatalog.swift`,
        light: `${folder}/__Snapshots__/SignInCatalog/${name}-light.png`,
        dark: `${folder}/__Snapshots__/SignInCatalog/${name}-dark.png`,
      })),
    });
    /** A repository with SignInCatalog's Mac and iPhone manifests and references. */
    const withRepository = async (
      swift: string,
      manifests: Record<string, unknown>,
      check: (repository: string) => Promise<void>,
    ) => {
      const repository = await mkdtemp(join(tmpdir(), "graphs-"));
      try {
        const write = async (path: string, contents: string) => {
          await mkdir(join(repository, path, ".."), { recursive: true });
          await writeFile(join(repository, path), contents);
        };
        await write(`${folder}/SignInCatalog.swift`, swift);
        for (const [file, json] of Object.entries(manifests)) {
          await write(`${folder}/__Snapshots__/SignInCatalog/${file}`, JSON.stringify(json));
        }
        for (const name of ["Out", "Web"]) {
          for (const appearance of ["light", "dark"]) {
            await write(`${folder}/__Snapshots__/SignInCatalog/${name}-${appearance}.png`, "");
          }
        }
        await check(repository);
      } finally {
        await rm(repository, { recursive: true, force: true });
      }
    };
    const swift = [
      '#if os(macOS)\nlet c = StateCatalog("Mac", states: s + [CatalogState("Web") {}])',
      '#else\nlet c = StateCatalog(phone: "iPhone", states: s)\n#endif',
      'let s = [CatalogState("Out") {}]',
    ].join("\n");
    const both = {
      "mac.json": manifest("health-mac", "Mac", ["Out", "Web"]),
      "iphone.json": manifest("health-iphone", "iPhone", ["Out"]),
    };

    it("gives each app its catalogs' states", async () => {
      await withRepository(swift, both, async (repository) => {
        const catalogs = await scanCatalogs(repository);
        expect(catalogs.get("health-mac")?.get("LilAuth/SignInCatalog.swift")).toEqual([
          "Out",
          "Web",
        ]);
        expect(catalogs.get("health-iphone")?.get("LilAuth/SignInCatalog.swift")).toEqual(["Out"]);
        expect(await manifestProblems(repository)).toEqual([]);
      });
    });

    it("finds manifests that are out of date or left behind", async () => {
      const renamed = swift.replace('"Out"', '"Signed out"').replace('"Mac"', '"Mac app"');
      await withRepository(renamed, both, async (repository) => {
        expect(await manifestProblems(repository)).toEqual([
          `${folder}/__Snapshots__/SignInCatalog/iphone.json: "Out" isn't in ${folder}/SignInCatalog.swift any more.`,
          `${folder}/__Snapshots__/SignInCatalog/mac.json: its screen, "Mac", isn't in ${folder}/SignInCatalog.swift. If it was renamed, delete the manifest and the old references.`,
          `${folder}/SignInCatalog.swift: "Web" isn't in a manifest.`,
          `${folder}/SignInCatalog.swift: "Signed out" isn't in a manifest.`,
        ]);
      });
      await withRepository(
        swift,
        {
          "mac.json": manifest("health-mac", "Mac", ["Out", "Web", "New"]),
          "old.json": {
            ...manifest("health-mac", "Old", ["Out"]),
            states: manifest("health-mac", "Old", ["Out"]).states.map((state) => ({
              ...state,
              source: `${folder}/OldCatalog.swift`,
            })),
          },
        },
        async (repository) => {
          expect(await manifestProblems(repository)).toEqual([
            `${folder}/__Snapshots__/SignInCatalog/mac.json: "New" isn't in ${folder}/SignInCatalog.swift any more.`,
            `${folder}/__Snapshots__/SignInCatalog/mac.json: "New" has no reference ${folder}/__Snapshots__/SignInCatalog/New-light.png.`,
            `${folder}/__Snapshots__/SignInCatalog/mac.json: "New" has no reference ${folder}/__Snapshots__/SignInCatalog/New-dark.png.`,
            `${folder}/__Snapshots__/SignInCatalog/old.json: ${folder}/OldCatalog.swift doesn't exist. Delete the manifest.`,
          ]);
        },
      );
    });
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

  it("checks the real graphs against the real previews and catalogs", async () => {
    const problems = await checkGraphs(await scanScreens());
    expect(Object.fromEntries(problems)).toEqual({});
    expect(await manifestProblems()).toEqual([]);
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
