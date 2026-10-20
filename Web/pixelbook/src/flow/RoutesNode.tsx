// Flowchart mode's routes between screens, with their labels: one node, sized to reach them all.
import type { NodeProps } from "@xyflow/react";
import type { RoutesNode } from "../lib/Elements.ts";

/** The routes: dagre's points, each ending in an arrowhead, and their labels at their centers. */
export function RoutesNodeView({
  data: { edges },
  positionAbsoluteX: left,
  positionAbsoluteY: top,
}: NodeProps<RoutesNode>) {
  return (
    <>
      {/* In canvas points, from the node's corner: sized to read when zoomed out. */}
      <svg className="absolute inset-0 size-full overflow-visible" aria-hidden="true">
        <defs>
          <marker
            id="route-arrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path className="fill-secondary" d="M 0 0 L 10 5 L 0 10 z" />
          </marker>
        </defs>
        {edges.map((edge, index) => (
          <polyline
            className="fill-none stroke-secondary stroke-6 [stroke-linejoin:round]"
            key={`${edge.from}/${edge.to}/${index}`}
            points={edge.points.map(({ x, y }) => `${x - left},${y - top}`).join(" ")}
            markerEnd="url(#route-arrow)"
          />
        ))}
      </svg>
      {edges.map(
        ({ from, to, label, labelAt }, index) =>
          label !== undefined &&
          labelAt !== undefined && (
            <div
              key={`${from}/${to}/${index}`}
              className="absolute w-max max-w-[280px] -translate-1/2 rounded-2xl border-2 border-border bg-background px-3.5 py-1.5 text-center text-[26px] leading-[1.2] font-semibold"
              style={{ left: labelAt.x - left, top: labelAt.y - top }}
            >
              {label}
            </div>
          ),
      )}
    </>
  );
}
