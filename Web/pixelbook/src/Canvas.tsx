// An infinite canvas on React Flow (851-2766): drag or scroll to pan, pinch (or ⌘/Ctrl-scroll) to
// zoom around the pointer. It renders only the nodes in view.
import {
  type Node,
  type NodeTypes,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
  useStore,
} from "@xyflow/react";
import { memo, useCallback, useEffect, useImperativeHandle, useRef, useState } from "react";

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

/** React Flow's light and dark colors are for its own nodes; Pixelbook's theme colors the rest. */
const flowStyle = { "--xy-attribution-background-color": "transparent" } as React.CSSProperties;

interface CanvasProps<N extends Node> {
  /** The content's size, in canvas points. */
  readonly width: number;
  readonly height: number;
  readonly nodes: N[];
  /** Stable: React Flow warns when they change. */
  readonly nodeTypes: NodeTypes;
  readonly handle: React.Ref<CanvasHandle>;
  /** With each zoom it moves to, once it's shown its start view. */
  readonly onZoomChange: (zoom: number) => void;
}

/** Memoized: its page re-renders with each zoom it reports, and the canvas needn't. */
export const Canvas = memo(function Canvas<N extends Node>(props: CanvasProps<N>) {
  return (
    <ReactFlowProvider>
      <Flow {...props} />
    </ReactFlowProvider>
  );
}) as <N extends Node>(props: CanvasProps<N>) => React.ReactNode;

function Flow<N extends Node>({
  width,
  height,
  nodes,
  nodeTypes,
  handle,
  onZoomChange,
}: CanvasProps<N>) {
  const { viewportInitialized, getViewport, setViewport } = useReactFlow<N>();
  const viewportWidth = useStore((state) => state.width);
  const viewportHeight = useStore((state) => state.height);
  const element = useRef<HTMLDivElement>(null);
  // Until the viewport's measured, the start view of a canvas wider than it, the usual case. The
  // server renders no nodes, since none are in a view without a size.
  const [defaultViewport] = useState(() => startView(width, 0));

  // Whether the view has moved since it started: until then, a viewport that changes size (a
  // sidebar shown, hidden or resized) starts it over, so it stays as wide as the viewport.
  const touched = useRef(false);
  const show = useCallback((view: View) => void setViewport(view), [setViewport]);
  // Whether it's shown its start view, rather than the default.
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

  // What React Flow's own input handling leaves out.
  useEffect(() => {
    const wrapper = element.current;
    if (wrapper === null) return;
    // A wheel that scrolls by pages, which React Flow takes as points: a page is a screen. Heard
    // first, on the way down to React Flow's listener.
    const wheel = (event: WheelEvent) => {
      if (event.deltaMode !== WheelEvent.DOM_DELTA_PAGE || event.ctrlKey || event.metaKey) return;
      event.preventDefault();
      event.stopPropagation();
      touched.current = true;
      const view = getViewport();
      show({
        ...view,
        x: view.x - event.deltaX * wrapper.clientWidth,
        y: view.y - event.deltaY * wrapper.clientHeight,
      });
    };
    // A trackpad's pinch in Safari on the Mac, which arrives as gesture events rather than as a
    // Ctrl-wheel. On a touch screen, React Flow zooms with the touches themselves, so the gesture
    // events that come with them are only kept from zooming the page.
    let touches = 0;
    const touch = (event: TouchEvent) => (touches = event.touches.length);
    let scale = 1;
    const start = (event: Event) => {
      event.preventDefault();
      scale = 1;
    };
    const change = (event: Event) => {
      event.preventDefault();
      if (touches > 0) return;
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
    const touchEvents = ["touchstart", "touchend", "touchcancel"] as const;
    wrapper.addEventListener("wheel", wheel, { capture: true, passive: false });
    for (const type of touchEvents) wrapper.addEventListener(type, touch, { capture: true });
    wrapper.addEventListener("gesturestart", start);
    wrapper.addEventListener("gesturechange", change);
    return () => {
      wrapper.removeEventListener("wheel", wheel, { capture: true });
      for (const type of touchEvents) wrapper.removeEventListener(type, touch, { capture: true });
      wrapper.removeEventListener("gesturestart", start);
      wrapper.removeEventListener("gesturechange", change);
    };
  }, [getViewport, show]);

  return (
    <ReactFlow
      ref={element}
      className="absolute! inset-0"
      nodes={nodes}
      nodeTypes={nodeTypes}
      defaultViewport={defaultViewport}
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
      // A canvas to look at, not to edit: nothing to select or delete, so Shift-dragging pans too.
      nodesDraggable={false}
      nodesConnectable={false}
      nodesFocusable={false}
      edgesFocusable={false}
      elementsSelectable={false}
      selectionKeyCode={null}
      multiSelectionKeyCode={null}
      deleteKeyCode={null}
      // Moved by input, rather than set: the event's `null` when it was set. A press starts a move
      // that only a drag continues, and one wheel event only starts one.
      onMoveStart={(event) => {
        if (event?.type === "wheel") touched.current = true;
      }}
      onMove={(event) => {
        if (event !== null) touched.current = true;
      }}
      attributionPosition="bottom-left"
      style={flowStyle}
    >
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
