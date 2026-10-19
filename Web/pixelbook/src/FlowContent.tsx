// Flowchart mode's canvas: edges with their labels, and a node per screen that steps through its
// states.
import { memo, useState } from "react";
import { type FlowLayout, type FlowNode, nodeHeader } from "./Flow.ts";
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
      {layout.edges.map((edge, index) =>
        edge.label === undefined || edge.labelAt === undefined ? null : (
          <div
            key={`${edge.from}/${edge.to}/${index}`}
            className="edge-label"
            style={{ left: edge.labelAt.x, top: edge.labelAt.y }}
          >
            {edge.label}
          </div>
        ),
      )}
      <Labels labels={layout.labels} />
      {layout.nodes.map((node) => (
        <Node key={node.key} node={node} onSelect={onSelect} />
      ))}
      {layout.unlinked.map((tile) => (
        <TileButton key={`${tile.app}/${tile.snapshot.id}`} tile={tile} onSelect={onSelect} />
      ))}
    </>
  );
});

/** A screen: its name, then one state at a time, with the others stacked behind it. */
function Node({
  node,
  onSelect,
}: {
  readonly node: FlowNode;
  readonly onSelect: (tile: Tile) => void;
}) {
  const [index, setIndex] = useState(0);
  const count = node.tiles.length;
  const tile = node.tiles[index % count];
  if (tile === undefined) return null;
  const step = (by: number) => setIndex((index + by + count) % count);
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
          <span className="node-state-name">{tile.snapshot.state}</span>
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
      <TileButton tile={{ ...tile, x: 0, y: nodeHeader }} onSelect={onSelect} />
    </div>
  );
}
