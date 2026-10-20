// An infinite canvas on React Flow (851-2766): drag or scroll to pan, pinch (or ⌘/Ctrl-scroll) to
// zoom around the pointer. It renders only the nodes in view.
import {
  type Edge,
  type EdgeTypes,
  type Node,
  type NodeTypes,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  useStore,
} from "@xyflow/react";
import { useCallback, useEffect, useImperativeHandle, useRef, useState } from "react";

export interface View {
  readonly x: number;
  readonly y: number;
  readonly zoom: number;
}

export const minZoom = 0.02;
export const maxZoom = 4;

const clampZoom = (zoom: number) => Math.min(maxZoom, Math.max(minZoom, zoom));

/** Zooms by `factor`, keeping the canvas point under (px, py), in screen points, in place. */
export const zoomAround = (view: View, factor: number, px: number, py: number): View => {
  const zoom = clampZoom(view.zoom * factor);
  const applied = zoom / view.zoom;
  return { zoom, x: px - (px - view.x) * applied, y: py - (py - view.y) * applied };
};

/**
 * The view that shows a `width` × `height` canvas whole in a viewport, at most at 100%. The
 * viewport is the canvas's own, between the header and the sidebars, so nothing covers it.
 */
export const fitView = (
  width: number,
  height: number,
  viewportWidth: number,
  viewportHeight: number,
): View => {
  const zoom = clampZoom(Math.min(viewportWidth / width, viewportHeight / height, 1));
  return {
    zoom,
    x: (viewportWidth - width * zoom) / 2,
    y: Math.max(0, (viewportHeight - height * zoom) / 2),
  };
};

/**
 * Where the canvas opens: its top left, as wide as the viewport, but no smaller than
 * `minimumZoom` so snapshots are recognizable. A tall canvas would otherwise fit at a few percent.
 */
export const startView = (width: number, viewportWidth: number, minimumZoom = 0.2): View => {
  const zoom = clampZoom(Math.min(Math.max(viewportWidth / width, minimumZoom), 1));
  return { zoom, x: Math.max(0, (viewportWidth - width * zoom) / 2), y: 0 };
};

export interface CanvasHandle {
  readonly zoomBy: (factor: number) => void;
  readonly fit: () => void;
}

/** Further than this, in screen points, a press is a drag, not a click. */
const dragThreshold = 4;

interface CanvasProps<N extends Node, E extends Edge> {
  /** The content's size, in canvas points. */
  readonly width: number;
  readonly height: number;
  readonly nodes: N[];
  readonly edges: E[];
  /** Stable: React Flow warns when they change. */
  readonly nodeTypes: NodeTypes;
  readonly edgeTypes: EdgeTypes;
  readonly handle: React.Ref<CanvasHandle>;
  /** With each zoom it moves to, once it's shown its start view. */
  readonly onZoomChange: (zoom: number) => void;
}

export function Canvas<N extends Node, E extends Edge>(props: CanvasProps<N, E>) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  );
}

function Flow<N extends Node, E extends Edge>({
  width,
  height,
  nodes,
  edges,
  nodeTypes,
  edgeTypes,
  handle,
  onZoomChange,
}: CanvasProps<N, E>) {
  const flow = useReactFlow<N, E>();
  const { viewportInitialized, getViewport, setViewport } = flow;
  const viewportWidth = useStore((state) => state.width);
  const viewportHeight = useStore((state) => state.height);
  const element = useRef<HTMLDivElement>(null);

  // Whether the view has moved since it started: until then, a viewport that changes size (a
  // sidebar shown, hidden or resized) starts it over, so it stays as wide as the viewport.
  const touched = useRef(false);
  const show = useCallback((view: View) => void setViewport(view), [setViewport]);
  // Whether it's shown its start view, rather than the server's guess.
  const [started, setStarted] = useState(false);
  // Starts over when the content changes, e.g. with a filter.
  useEffect(() => {
    touched.current = false;
  }, [width, height]);
  useEffect(() => {
    if (!viewportInitialized || viewportWidth === 0 || touched.current) return;
    show(startView(width, viewportWidth));
    setStarted(true);
  }, [viewportInitialized, viewportWidth, width, height, show]);

  useImperativeHandle(
    handle,
    () => ({
      fit: () => {
        touched.current = true;
        show(fitView(width, height, viewportWidth, viewportHeight));
      },
      zoomBy: (factor) => {
        touched.current = true;
        show(zoomAround(getViewport(), factor, viewportWidth / 2, viewportHeight / 2));
      },
    }),
    [width, height, viewportWidth, viewportHeight, getViewport, show],
  );

  // Safari's pinch, which arrives as gesture events rather than React Flow's Ctrl-wheel.
  useEffect(() => {
    const wrapper = element.current;
    if (wrapper === null) return;
    let scale = 1;
    const start = (event: Event) => {
      event.preventDefault();
      scale = 1;
    };
    const change = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      const bounds = wrapper.getBoundingClientRect();
      const factor = gesture.scale / scale;
      scale = gesture.scale;
      touched.current = true;
      show(
        zoomAround(
          getViewport(),
          factor,
          gesture.clientX - bounds.left,
          gesture.clientY - bounds.top,
        ),
      );
    };
    wrapper.addEventListener("gesturestart", start);
    wrapper.addEventListener("gesturechange", change);
    return () => {
      wrapper.removeEventListener("gesturestart", start);
      wrapper.removeEventListener("gesturechange", change);
    };
  }, [getViewport, show]);

  return (
    <ReactFlow
      ref={element}
      className="absolute! inset-0"
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      // The server's guess, for a canvas wider than the viewport, the usual case.
      defaultViewport={startView(width, 0)}
      minZoom={minZoom}
      maxZoom={maxZoom}
      // Only the nodes in view are in the DOM. Its own culling (851-2713's render region) costs more:
      // every node React Flow mounts, even hidden, reads its store on every frame of panning.
      onlyRenderVisibleElements
      // Scrolling pans, as in Figma; pinching or ⌘-scrolling zooms.
      panOnScroll
      panOnScrollSpeed={1}
      zoomOnScroll={false}
      zoomOnDoubleClick={false}
      paneClickDistance={dragThreshold}
      // A canvas to look at, not to edit.
      nodesDraggable={false}
      nodesConnectable={false}
      nodesFocusable={false}
      edgesFocusable={false}
      elementsSelectable={false}
      onMoveStart={(event) => {
        // `null` when the view was set, rather than moved by input.
        if (event !== null) touched.current = true;
      }}
      attributionPosition="bottom-left"
      // React Flow's light and dark colors are for its own nodes; Pixelbook's theme colors the rest.
      style={{ "--xy-attribution-background-color": "transparent" } as React.CSSProperties}
    >
      <ArrowMarker />
      {started && <ZoomReporter onZoomChange={onZoomChange} />}
    </ReactFlow>
  );
}

/** Reports the zoom as it changes: its own component, so the canvas doesn't re-render with it. */
function ZoomReporter({ onZoomChange }: { readonly onZoomChange: (zoom: number) => void }) {
  const zoom = useStore((state) => state.transform[2]);
  useEffect(() => onZoomChange(zoom), [zoom, onZoomChange]);
  return null;
}

/** The arrowhead at the end of a flowchart route (`markerEnd="url(#route-arrow)"`). */
function ArrowMarker() {
  return (
    <svg className="absolute size-0" aria-hidden="true">
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
    </svg>
  );
}
