// Flowchart mode: each app's screens laid out by its graph file, a screen per node showing one state
// at a time, with the screens the graph leaves out in rows below. Positions are in points.
import dagre from "@dagrejs/dagre";
import type { Graph } from "./Graph.ts";
import {
  byText,
  type Filters,
  type Label,
  layoutRow,
  shows,
  sourceOrder,
  spacing,
  type Tile,
} from "./Grid.ts";
import { appName, type Manifest, type Scheme, schemes, type Snapshot } from "./Snapshots.ts";

/** A screen on the flowchart: one of its states at a time. */
export interface FlowNode {
  readonly key: string;
  readonly title: string;
  /**
   * Its states' tiles, in the order the graph gives; the first shows to start with. None if the
   * graph names a screen this app has no snapshots of here, which shows as a placeholder.
   */
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

/** A placeholder's size, for a screen without snapshots. */
export const placeholder = { width: 480, height: 240 };

/** Rows of screens left out of the graph wrap after this width, in points. */
export const unlinkedRowWidth = 8000;

/** `Module/File.swift`, as graph files name screens. */
const screenKey = (snapshot: Snapshot) => `${snapshot.module}/${snapshot.file}`;

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
    const tileFor = (snapshot: Snapshot) => layoutRow(manifest, [snapshot], [scheme]).tiles[0];

    // The graph's screens, with the states it names (all, by default) that have this scheme.
    const graphed = (graph?.screens ?? []).map((screen) => {
      const snapshots = byScreen.get(screen.screen) ?? [];
      const chosen =
        screen.states === undefined
          ? snapshots
          : screen.states.flatMap((state) => snapshots.filter((s) => s.state === state));
      const tiles = chosen.flatMap((snapshot) => tileFor(snapshot) ?? []);
      return { id: screen.id, title: snapshots[0]?.screen ?? screen.screen, tiles };
    });
    // Screens the graph leaves out, so a missing one is easy to spot.
    const inGraph = new Set(graph?.screens.map((screen) => screen.screen));
    const rest = [...byScreen.keys()]
      .filter((key) => !inGraph.has(key))
      .flatMap((key) => {
        const first = byScreen.get(key)?.find((snapshot) => tileFor(snapshot) !== undefined);
        return first === undefined ? [] : [first];
      })
      .toSorted((a, b) => byText(a.screen, b.screen));
    // An app with nothing in this appearance gets no section.
    const anyGraphed = graphed.some((screen) => screen.tiles.length > 0);
    if (!anyGraphed && rest.length === 0) continue;

    if (labels.length > 0) y += spacing.app;
    labels.push({
      kind: "app",
      text: appName(manifest.app, manifest.platform),
      x: spacing.margin,
      y,
    });
    y += spacing.appLabel;

    if (graph !== undefined && anyGraphed) {
      // Sized by the state shown first, so edges meet what's on screen. Other states can be
      // larger, and overlap their neighbors while they're showing.
      const sizes = new Map(
        graphed.map(({ id, tiles }) => {
          const first = tiles[0] ?? placeholder;
          return [id, { width: first.width, height: nodeHeader + first.height }] as const;
        }),
      );
      const flow = layoutFlow(graph, sizes);
      // dagre's coordinates start near 0, but nudges can go negative.
      const left = Math.min(...flow.screens.map((screen) => screen.x), 0);
      const top = Math.min(...flow.screens.map((screen) => screen.y), 0);
      const dx = spacing.margin - left;
      const dy = y - top;
      let bottom = y;
      const byId = new Map(graphed.map((screen) => [screen.id, screen]));
      for (const placed of flow.screens) {
        const { title, tiles } = byId.get(placed.id) ?? { title: "", tiles: [] };
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

    if (rest.length > 0) {
      if (anyGraphed) y += spacing.row;
      const text = graph === undefined ? "No graph yet" : "Not in the graph";
      labels.push({ kind: "screen", text, x: spacing.margin, y });
      y += spacing.screenLabel;
      // Each screen's name above its tile, in rows that wrap.
      const tiles = layoutRow(manifest, rest, [scheme]).tiles;
      let x = 0;
      let rowHeight = 0;
      for (const tile of tiles) {
        if (x > 0 && x + tile.width > unlinkedRowWidth) {
          y += spacing.screenLabel + rowHeight + spacing.row;
          x = 0;
          rowHeight = 0;
        }
        const placed = { ...tile, x: spacing.margin + x, y: y + spacing.screenLabel };
        labels.push({ kind: "caption", text: tile.snapshot.screen, x: placed.x, y });
        unlinked.push(placed);
        x += tile.width + spacing.tile;
        rowHeight = Math.max(rowHeight, tile.height);
        width = Math.max(width, placed.x + tile.width);
      }
      y += spacing.screenLabel + rowHeight;
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

/** A screen placed on the canvas: its top-left corner and size, in points. */
export interface PlacedScreen {
  readonly id: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** An edge's route, through points on the canvas, and where its label goes. */
export interface PlacedEdge {
  readonly from: string;
  readonly to: string;
  readonly label: string | undefined;
  readonly points: ReadonlyArray<{ readonly x: number; readonly y: number }>;
  readonly labelAt: { readonly x: number; readonly y: number } | undefined;
}

/** Spacing between screens, in points. */
// Edge labels' room matches their CSS (`.edge-label`): up to 280 wide plus padding, two lines.
export const flowSpacing = { rank: 320, node: 120, label: { width: 320, height: 96 } };

/**
 * Lays a graph out left to right with dagre, given each screen's size, then applies nudges. Edges
 * that a nudge moved an end of are drawn straight between the screens.
 */
export const layoutFlow = (
  graph: Graph,
  sizes: ReadonlyMap<string, { readonly width: number; readonly height: number }>,
): { readonly screens: ReadonlyArray<PlacedScreen>; readonly edges: ReadonlyArray<PlacedEdge> } => {
  const shown = graph.screens.filter((screen) => sizes.has(screen.id));
  const g = new dagre.graphlib.Graph({ multigraph: true });
  g.setGraph({ rankdir: "LR", ranksep: flowSpacing.rank, nodesep: flowSpacing.node });
  g.setDefaultEdgeLabel(() => ({}));
  for (const screen of shown) {
    const size = sizes.get(screen.id) ?? { width: 0, height: 0 };
    g.setNode(screen.id, { width: size.width, height: size.height });
  }
  const edges = graph.edges.filter((edge) => g.hasNode(edge.from) && g.hasNode(edge.to));
  for (const [index, edge] of edges.entries()) {
    const label = edge.label === undefined ? {} : flowSpacing.label;
    g.setEdge(edge.from, edge.to, { ...label, labelpos: "c" }, String(index));
  }
  dagre.layout(g);

  const nudges = new Map(shown.map((screen) => [screen.id, screen.nudge ?? [0, 0]] as const));
  const placed = shown.map((screen): PlacedScreen => {
    const node = g.node(screen.id);
    const [dx, dy] = nudges.get(screen.id) ?? [0, 0];
    return {
      id: screen.id,
      x: node.x - node.width / 2 + dx,
      y: node.y - node.height / 2 + dy,
      width: node.width,
      height: node.height,
    };
  });
  const byId = new Map(placed.map((screen) => [screen.id, screen]));
  const nudged = (id: string) => {
    const [dx, dy] = nudges.get(id) ?? [0, 0];
    return dx !== 0 || dy !== 0;
  };
  const placedEdges = edges.map((edge, index): PlacedEdge => {
    const routed = g.edge({ v: edge.from, w: edge.to, name: String(index) });
    const from = byId.get(edge.from);
    const to = byId.get(edge.to);
    if ((nudged(edge.from) || nudged(edge.to)) && from !== undefined && to !== undefined) {
      const start = { x: from.x + from.width, y: from.y + from.height / 2 };
      const end = { x: to.x, y: to.y + to.height / 2 };
      const middle = { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 };
      return { ...edge, label: edge.label, points: [start, end], labelAt: middle };
    }
    const labelAt =
      routed.x === undefined || routed.y === undefined ? undefined : { x: routed.x, y: routed.y };
    return { ...edge, label: edge.label, points: routed.points ?? [], labelAt };
  });
  return { screens: placed, edges: placedEdges };
};
