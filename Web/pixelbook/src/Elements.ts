// What the canvas shows, as React Flow's nodes and edges (851-2766): snapshot tiles and labels in
// both modes, and the flowchart's screens with the routes between them. The layouts are ours.
import { type Edge, type Node, Position } from "@xyflow/react";
import { type FlowLayout, type FlowNode, nodeExtent, type PlacedEdge } from "./Flow.ts";
import { type Label, type Tile, tileId } from "./Grid.ts";

export type TileNode = Node<{ readonly tile: Tile }, "tile">;
export type LabelNode = Node<{ readonly label: Label }, "label">;
/** A flowchart screen, stepped `steps` times through its states. */
export type ScreenNode = Node<{ readonly node: FlowNode; readonly steps: number }, "screen">;
export type CanvasNode = TileNode | LabelNode | ScreenNode;
export type RouteEdge = Edge<{ readonly edge: PlacedEdge }, "route">;

export interface Elements {
  readonly nodes: CanvasNode[];
  readonly edges: RouteEdge[];
}

/**
 * Room for a label's text, which isn't measured, in points: an app's title (`.label.app`, 112
 * points) runs to about 1,500 points.
 */
export const labelExtent = { width: 2000, height: 120 };

// Every node comes with its size and its handles, so React Flow renders only those in view from
// the start, rather than every node once to measure it.

const tileNode = (tile: Tile): TileNode => ({
  id: `tile/${tileId(tile)}`,
  type: "tile",
  position: { x: tile.x, y: tile.y },
  width: tile.width,
  height: tile.height,
  handles: [],
  data: { tile },
});

const labelNode = (label: Label): LabelNode => ({
  id: `label/${label.kind}/${label.x}/${label.y}`,
  type: "label",
  position: { x: label.x, y: label.y },
  ...labelExtent,
  handles: [],
  data: { label },
});

const screenId = (key: string) => `screen/${key}`;

/** Its size reaches as far as its largest state (`nodeExtent`), so it shows while any is in view. */
const screenNode = (node: FlowNode, steps: number): ScreenNode => {
  const { width, height } = nodeExtent(node);
  const stepped = node.tiles.length > 0 && steps % node.tiles.length > 0;
  return {
    id: screenId(node.key),
    type: "screen",
    position: { x: node.x, y: node.y },
    width,
    height,
    // Raised once stepped, since another state can be larger than the first and overlap.
    zIndex: stepped ? 1 : 0,
    // Where routes start and end, for React Flow, which draws an edge only between handles. The
    // routes themselves are dagre's.
    handles: [
      { type: "target", position: Position.Left, x: 0, y: node.height / 2 },
      { type: "source", position: Position.Right, x: node.width, y: node.height / 2 },
    ],
    data: { node, steps },
  };
};

const routeEdge = (edge: PlacedEdge, index: number): RouteEdge => ({
  id: `route/${edge.from}/${edge.to}/${index}`,
  type: "route",
  source: screenId(edge.from),
  target: screenId(edge.to),
  data: { edge },
});

/** The grid's, or a comparison's: labels, then tiles. */
export const gridElements = (layout: {
  readonly tiles: ReadonlyArray<Tile>;
  readonly labels: ReadonlyArray<Label>;
}): Elements => ({
  nodes: [...layout.labels.map(labelNode), ...layout.tiles.map(tileNode)],
  edges: [],
});

/** The flowchart's, with each screen stepped as far as `steps` has it, by its key. */
export const flowElements = (layout: FlowLayout, steps: ReadonlyMap<string, number>): Elements => ({
  nodes: [
    ...layout.labels.map(labelNode),
    ...layout.nodes.map((node) => screenNode(node, steps.get(node.key) ?? 0)),
    ...layout.unlinked.map(tileNode),
  ],
  edges: layout.edges.map(routeEdge),
});
