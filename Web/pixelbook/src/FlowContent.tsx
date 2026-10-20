// Flowchart mode's canvas: edges with their labels, and a node per screen that steps through its
// states.
import { memo, useCallback, useState } from "react";
import { useNear } from "./Canvas.tsx";
import { type FlowLayout, type FlowNode, flowSpacing, nodeExtent, nodeHeader } from "./Flow.ts";
import type { Tile } from "./Grid.ts";
import { Labels, TileButton } from "./Tiles.tsx";

/** Memoized: panning and zooming don't change it. */
export const FlowContent = memo(function FlowContent({
  layout,
  onSelect,
}: {
  readonly layout: FlowLayout;
  readonly onSelect: (tile: Tile) => void;
}) {
  // Only what's near the view; the edges stay one drawing.
  const nodes = useNear(layout.nodes, nodeExtent);
  const unlinked = useNear(layout.unlinked, (tile) => tile);
  // Placed at their centers, with the room the layout gave them.
  const edgeLabels = useNear(
    layout.edges.flatMap((edge, index) =>
      edge.label === undefined || edge.labelAt === undefined
        ? []
        : [{ key: `${edge.from}/${edge.to}/${index}`, text: edge.label, at: edge.labelAt }],
    ),
    ({ at }) => ({
      x: at.x - flowSpacing.label.width / 2,
      y: at.y - flowSpacing.label.height / 2,
      ...flowSpacing.label,
    }),
  );
  // How far each node was stepped, kept here so a node that leaves the view and comes back keeps
  // its state.
  const [steps, setSteps] = useState<ReadonlyMap<string, number>>(new Map());
  const step = useCallback(
    (key: string, to: number) => setSteps((steps) => new Map(steps).set(key, to)),
    [],
  );
  return (
    <>
      <svg className="edges" width={layout.width} height={layout.height} aria-hidden="true">
        <defs>
          <marker
            id="arrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" />
          </marker>
        </defs>
        {layout.edges.map((edge, index) => (
          <polyline
            key={`${edge.from}/${edge.to}/${index}`}
            points={edge.points.map(({ x, y }) => `${x},${y}`).join(" ")}
            markerEnd="url(#arrow)"
          />
        ))}
      </svg>
      {edgeLabels.map((label) => (
        <div key={label.key} className="edge-label" style={{ left: label.at.x, top: label.at.y }}>
          {label.text}
        </div>
      ))}
      <Labels labels={layout.labels} />
      {nodes.map((node) => (
        <Node
          key={node.key}
          node={node}
          steps={steps.get(node.key) ?? 0}
          onStep={step}
          onSelect={onSelect}
        />
      ))}
      {unlinked.map((tile) => (
        <TileButton key={`${tile.app}/${tile.snapshot.id}`} tile={tile} onSelect={onSelect} />
      ))}
    </>
  );
});

/** A screen: its name, then one state at a time, with the others stacked behind it. */
function Node({
  node,
  steps,
  onStep,
  onSelect,
}: {
  readonly node: FlowNode;
  /** How far it was stepped through its states. */
  readonly steps: number;
  readonly onStep: (key: string, steps: number) => void;
  readonly onSelect: (tile: Tile) => void;
}) {
  const count = node.tiles.length;
  // Wrapped here, since filters can leave a node fewer states than it was stepped through.
  const index = count === 0 ? 0 : steps % count;
  const tile = node.tiles[index];
  const step = (by: number) => onStep(node.key, index + by + count);
  return (
    <div
      // Raised once stepped, since another state can be larger than the first and overlap.
      className={["node", count > 1 ? "stacked" : "", index > 0 ? "raised" : ""].join(" ")}
      style={{ left: node.x, top: node.y, width: node.width, height: node.height }}
    >
      <header className="node-header" style={{ height: nodeHeader }}>
        <div className="node-title">{node.title}</div>
        <div className="node-state">
          {count > 1 && (
            <button type="button" onClick={() => step(-1)} aria-label="Previous state">
              ‹
            </button>
          )}
          <span className="node-state-name">{tile?.snapshot.state ?? "No snapshots"}</span>
          {count > 1 && (
            <>
              <span className="node-count">
                {index + 1}/{count}
              </span>
              <button type="button" onClick={() => step(1)} aria-label="Next state">
                ›
              </button>
            </>
          )}
        </div>
      </header>
      {tile === undefined ? (
        // The graph names a screen with no snapshots here: not rendered for this app, or none in
        // this appearance.
        <div className="placeholder" style={{ top: nodeHeader, height: node.height - nodeHeader }}>
          No snapshots of {node.title} for this app in this appearance
        </div>
      ) : (
        <TileButton tile={{ ...tile, x: 0, y: nodeHeader }} onSelect={onSelect} />
      )}
    </div>
  );
}
