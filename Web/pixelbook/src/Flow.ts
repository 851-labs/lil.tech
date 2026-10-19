// Flowchart mode: each app's screens laid out by its graph file, a screen per node showing one state
// at a time, with the screens the graph leaves out in a row below. Positions are in points.
import { type Graph, layoutFlow, type PlacedEdge } from "./Graph.ts";
import { byText, type Filters, type Label, layoutRow, shows, spacing, type Tile } from "./Grid.ts";
import { appName, type Manifest, type Scheme, schemes, type Snapshot } from "./Snapshots.ts";

/** A screen on the flowchart: one of its states at a time. */
export interface FlowNode {
  readonly key: string;
  readonly title: string;
  /** Its states' tiles, in the order the graph gives; the first shows to start with. */
  readonly tiles: ReadonlyArray<Tile>;
  readonly x: number;
  readonly y: number;
  /** The node's size: its header, and the state it shows first. */
  readonly width: number;
  readonly height: number;
}

export interface FlowLayout {
  readonly nodes: ReadonlyArray<FlowNode>;
  readonly edges: ReadonlyArray<PlacedEdge>;
  readonly labels: ReadonlyArray<Label>;
  /** Screens that aren't in their app's graph, each in its first state. */
  readonly unlinked: ReadonlyArray<Tile>;
  readonly width: number;
  readonly height: number;
}

/** The height of a node's header: its screen's name, its state and the state picker. */
export const nodeHeader = 112;

/** `Module/File.swift`, as graph files name screens. */
const screenKey = (snapshot: Snapshot) => `${snapshot.module}/${snapshot.file}`;

const sourceOrder = (a: Snapshot, b: Snapshot) =>
  (a.line ?? 0) - (b.line ?? 0) || byText(a.state, b.state);

/**
 * Lays out each shown app's flowchart, one app below another. Each node shows the first color
 * scheme the filters show, light if both.
 */
export const layoutFlowchart = (
  manifests: ReadonlyArray<Manifest>,
  graphs: ReadonlyArray<Graph>,
  filters: Filters,
): FlowLayout => {
  const scheme: Scheme | undefined = schemes.find((scheme) => shows(filters.schemes, scheme));
  const nodes: FlowNode[] = [];
  const edges: PlacedEdge[] = [];
  const labels: Label[] = [];
  const unlinked: Tile[] = [];
  let y = spacing.margin;
  let width = 0;
  const shown = manifests
    .filter((manifest) => shows(filters.apps, manifest.app))
    .filter((manifest) => shows(filters.platforms, manifest.platform))
    .toSorted((a, b) => byText(a.app, b.app));
  if (scheme === undefined) return { nodes, edges, labels, unlinked, width: 0, height: 0 };

  for (const manifest of shown) {
    const graph = graphs.find((graph) => graph.app === manifest.app);
    const byScreen = Map.groupBy(manifest.snapshots.toSorted(sourceOrder), screenKey);
    const tileFor = (snapshot: Snapshot): Tile | undefined => {
      const variant = snapshot.variants[scheme];
      if (variant === undefined) return undefined;
      const { app, platform } = manifest;
      const size = { width: variant.width / variant.scale, height: variant.height / variant.scale };
      return { app, platform, snapshot, scheme, variant, x: 0, y: 0, ...size };
    };

    if (labels.length > 0) y += spacing.app;
    labels.push({
      kind: "app",
      text: appName(manifest.app, manifest.platform),
      x: spacing.margin,
      y,
    });
    y += spacing.appLabel;

    // The graph's screens, with the states it names (all, by default) that have this scheme.
    const graphed = new Map<string, { title: string; tiles: Tile[] }>();
    for (const screen of graph?.screens ?? []) {
      const snapshots = byScreen.get(screen.screen) ?? [];
      const chosen =
        screen.states === undefined
          ? snapshots
          : screen.states.flatMap((state) => snapshots.filter((s) => s.state === state));
      const tiles = chosen.flatMap((snapshot) => tileFor(snapshot) ?? []);
      const title = snapshots[0]?.screen ?? screen.screen;
      if (tiles.length > 0) graphed.set(screen.id, { title, tiles });
    }
    if (graph !== undefined && graphed.size > 0) {
      // Sized by the state shown first, so edges meet what's on screen. Other states can be
      // larger, and overlap their neighbors while they're showing.
      const sizes = new Map(
        [...graphed].map(([id, { tiles }]) => [
          id,
          { width: tiles[0]?.width ?? 0, height: nodeHeader + (tiles[0]?.height ?? 0) },
        ]),
      );
      const flow = layoutFlow(graph, sizes);
      // dagre's coordinates start near 0, but nudges can go negative.
      const left = Math.min(...flow.screens.map((screen) => screen.x), 0);
      const top = Math.min(...flow.screens.map((screen) => screen.y), 0);
      const dx = spacing.margin - left;
      const dy = y - top;
      let bottom = y;
      for (const placed of flow.screens) {
        const { title, tiles } = graphed.get(placed.id) ?? { title: "", tiles: [] };
        const node = { ...placed, x: placed.x + dx, y: placed.y + dy };
        nodes.push({ key: `${manifest.app}/${placed.id}`, title, tiles, ...node });
        bottom = Math.max(bottom, node.y + node.height);
        width = Math.max(width, node.x + node.width);
      }
      for (const edge of flow.edges) {
        const move = (point: { x: number; y: number }) => ({ x: point.x + dx, y: point.y + dy });
        edges.push({
          ...edge,
          from: `${manifest.app}/${edge.from}`,
          to: `${manifest.app}/${edge.to}`,
          points: edge.points.map(move),
          labelAt: edge.labelAt === undefined ? undefined : move(edge.labelAt),
        });
      }
      y = bottom;
    }

    // Screens the graph leaves out, so a missing one is easy to spot.
    const inGraph = new Set(graph?.screens.map((screen) => screen.screen));
    const rest = [...byScreen.keys()]
      .filter((key) => !inGraph.has(key))
      .flatMap((key) => {
        const snapshots = byScreen.get(key) ?? [];
        const first = snapshots.find((snapshot) => snapshot.variants[scheme] !== undefined);
        return first === undefined ? [] : [first];
      })
      .toSorted((a, b) => byText(a.screen, b.screen));
    if (rest.length > 0) {
      if (graphed.size > 0) y += spacing.row;
      labels.push({
        kind: "screen",
        text: graph === undefined ? "No graph yet" : "Not in the graph",
        x: spacing.margin,
        y,
      });
      y += spacing.screenLabel;
      const row = layoutRow(manifest, rest, [scheme]);
      // Each screen's name above its tile.
      y += spacing.screenLabel;
      for (const tile of row.tiles) {
        const x = spacing.margin + tile.x;
        labels.push({ kind: "caption", text: tile.snapshot.screen, x, y: y - spacing.screenLabel });
        unlinked.push({ ...tile, x, y });
      }
      width = Math.max(width, spacing.margin + row.width);
      y += row.height;
    }
  }
  return {
    nodes,
    edges,
    labels,
    unlinked,
    width: width + spacing.margin,
    height: y + spacing.margin,
  };
};
