// An infinite canvas: drag or scroll to pan, pinch (or ⌘/Ctrl-scroll) to zoom around the pointer.
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";

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

/** The space the toolbar covers at the top of the viewport, in screen points. */
const toolbarHeight = 64;

/** The view that shows a `width` × `height` canvas whole in a viewport, at most at 100%. */
export const fitView = (
  width: number,
  height: number,
  viewportWidth: number,
  viewportHeight: number,
): View => {
  const visibleHeight = viewportHeight - toolbarHeight;
  const zoom = clampZoom(Math.min(viewportWidth / width, visibleHeight / height, 1));
  return {
    zoom,
    x: (viewportWidth - width * zoom) / 2,
    y: toolbarHeight + Math.max(0, (visibleHeight - height * zoom) / 2),
  };
};

/**
 * Where the canvas opens: its top left, as wide as the viewport, but no smaller than
 * `minimumZoom` so snapshots are recognizable. A tall canvas would otherwise fit at a few percent.
 */
export const startView = (width: number, viewportWidth: number, minimumZoom = 0.2): View => {
  const zoom = clampZoom(Math.min(Math.max(viewportWidth / width, minimumZoom), 1));
  return { zoom, x: Math.max(0, (viewportWidth - width * zoom) / 2), y: toolbarHeight };
};

/** A rectangle on the canvas, in canvas points: from (x0, y0) to (x1, y1). */
export interface Region {
  readonly x0: number;
  readonly y0: number;
  readonly x1: number;
  readonly y1: number;
}

/**
 * The part of the canvas worth rendering (851-2713): what's in view, with half a screen around it
 * so panning at normal speed finds it rendered. It's snapped outward to cells a quarter of a
 * screen, rounded up to a power of two, so it only changes every quarter screen of panning, or as
 * zooming doubles or halves.
 */
export const renderRegion = (view: View, viewportWidth: number, viewportHeight: number): Region => {
  const width = viewportWidth / view.zoom;
  const height = viewportHeight / view.zoom;
  const cell = 2 ** Math.ceil(Math.log2(Math.max(width, height) / 4));
  const left = -view.x / view.zoom;
  const top = -view.y / view.zoom;
  return {
    x0: Math.floor((left - width / 2) / cell) * cell,
    y0: Math.floor((top - height / 2) / cell) * cell,
    x1: Math.ceil((left + width * 1.5) / cell) * cell,
    y1: Math.ceil((top + height * 1.5) / cell) * cell,
  };
};

/** A rectangle on the canvas, in canvas points. */
export interface Box {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Whether `box` reaches into `region`. */
export const intersects = (region: Region, { x, y, width, height }: Box) =>
  x < region.x1 && x + width > region.x0 && y < region.y1 && y + height > region.y0;

/**
 * The canvas's `renderRegion`, for its content to render only what's in it. `undefined` until the
 * viewport's size is known (on the server, say): everything.
 */
export const RegionContext = createContext<Region | undefined>(undefined);

/** The items whose `box` reaches into `region`: all of them without one. */
export const near = <A,>(
  region: Region | undefined,
  items: ReadonlyArray<A>,
  box: (item: A) => Box,
): ReadonlyArray<A> =>
  region === undefined ? items : items.filter((item) => intersects(region, box(item)));

/**
 * The items near the canvas's view, for content to render only those. Off-screen content is then
 * out of the DOM: out of tab order and the browser's find, which the canvas's size makes the
 * better trade.
 */
export const useNear = <A,>(items: ReadonlyArray<A>, box: (item: A) => Box) =>
  near(useContext(RegionContext), items, box);

/** The canvas content's CSS transform for a view. */
const transformOf = (view: View) => `translate(${view.x}px, ${view.y}px) scale(${view.zoom})`;

const sameRegion = (a: Region, b: Region) =>
  a.x0 === b.x0 && a.y0 === b.y0 && a.x1 === b.x1 && a.y1 === b.y1;

/**
 * Whether a view that input moved to needs React to render it, rather than only moving the
 * canvas (851-2714): when it zooms (the zoom shown, and which images tiles load) or reaches another
 * render region. Panning within one only moves the canvas, and renders once input stops.
 */
export const needsRender = (
  live: View,
  rendered: View,
  viewport: { readonly width: number; readonly height: number } | undefined,
) => {
  if (live.zoom !== rendered.zoom) return true;
  if (viewport === undefined || viewport.width === 0 || viewport.height === 0) return false;
  return !sameRegion(
    renderRegion(live, viewport.width, viewport.height),
    renderRegion(rendered, viewport.width, viewport.height),
  );
};

/** After input stops for this long, the view it moved to renders. */
const settleDelay = 150;

export interface CanvasHandle {
  readonly zoomBy: (factor: number) => void;
  readonly fit: () => void;
}

/** Further than this, a press is a drag, not a click. */
const dragThreshold = 4;

export function Canvas({
  width,
  height,
  handle,
  onViewChange,
  children,
}: {
  /** The content's size, in canvas points. */
  readonly width: number;
  readonly height: number;
  readonly handle: React.Ref<CanvasHandle>;
  readonly onViewChange: (view: View) => void;
  readonly children: ReactNode;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  // The start view for a canvas wider than the viewport, the usual case, so the server renders
  // what the browser starts with. This is the view React renders.
  const [view, setView] = useState<View>(() => startView(width, 0));
  const [dragging, setDragging] = useState(false);
  // Whether the view is the browser's, from the viewport's size, rather than the server's guess.
  const [measured, setMeasured] = useState(false);
  const [viewportSize, setViewportSize] = useState<{ width: number; height: number }>();
  const size = useRef(viewportSize);
  useEffect(() => {
    const element = viewport.current;
    if (element === null) return;
    const observer = new ResizeObserver(() => {
      size.current = { width: element.clientWidth, height: element.clientHeight };
      setViewportSize(size.current);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // Wheel, pinch and drag events come faster than the screen refreshes, so they move `live`,
  // and once a frame the canvas moves to it directly, before that frame paints. React renders it
  // only when what it shows depends on it (`needsRender`), or once input stops (851-2714).
  const live = useRef(view);
  const rendered = useRef(view);
  const frame = useRef<number | undefined>(undefined);
  const settle = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const stopMoving = useCallback(() => {
    if (frame.current !== undefined) cancelAnimationFrame(frame.current);
    frame.current = undefined;
    clearTimeout(settle.current);
  }, []);
  /** Shows a view at once, dropping any input not yet shown: Fit, the zoom buttons, a reset. */
  const show = useCallback(
    (next: View) => {
      stopMoving();
      live.current = next;
      setView(next);
    },
    [stopMoving],
  );
  const change = useCallback((update: (view: View) => View) => {
    live.current = update(live.current);
    if (frame.current !== undefined) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = undefined;
      const next = live.current;
      if (content.current !== null) content.current.style.transform = transformOf(next);
      clearTimeout(settle.current);
      if (needsRender(next, rendered.current, size.current)) setView(next);
      else settle.current = setTimeout(() => setView(live.current), settleDelay);
    });
  }, []);
  useEffect(() => stopMoving, [stopMoving]);
  // React writes the view it rendered, which input may have moved past since: put the canvas
  // back where input has it, before the frame paints.
  useLayoutEffect(() => {
    rendered.current = view;
    if (content.current !== null) content.current.style.transform = transformOf(live.current);
  }, [view]);
  // A viewport with no size (hidden, say) shows nothing anyway, and its region would be NaN.
  const region =
    viewportSize === undefined || viewportSize.width === 0 || viewportSize.height === 0
      ? undefined
      : renderRegion(view, viewportSize.width, viewportSize.height);
  // The same object while the snapped bounds are, so content re-renders only when they change.
  const { x0, y0, x1, y1 } = region ?? {};
  const stableRegion = useMemo(
    () =>
      x0 === undefined || y0 === undefined || x1 === undefined || y1 === undefined
        ? undefined
        : { x0, y0, x1, y1 },
    [x0, y0, x1, y1],
  );

  useEffect(() => {
    if (measured) onViewChange(view);
  }, [view, measured, onViewChange]);

  const fit = useCallback(() => {
    const element = viewport.current;
    if (element === null) return;
    show(fitView(width, height, element.clientWidth, element.clientHeight));
  }, [width, height, show]);
  // Starts over when the content changes, e.g. with a filter.
  useEffect(() => {
    const element = viewport.current;
    if (element === null) return;
    show(startView(width, element.clientWidth));
    setMeasured(true);
  }, [width, height, show]);

  useImperativeHandle(
    handle,
    () => ({
      fit,
      zoomBy: (factor) => {
        const element = viewport.current;
        if (element === null) return;
        show(zoomAround(live.current, factor, element.clientWidth / 2, element.clientHeight / 2));
      },
    }),
    [fit, show],
  );

  // Wheel and Safari's gesture events, which React only listens to passively.
  useEffect(() => {
    const element = viewport.current;
    if (element === null) return;
    const point = (event: { clientX: number; clientY: number }) => {
      const bounds = element.getBoundingClientRect();
      return [event.clientX - bounds.left, event.clientY - bounds.top] as const;
    };
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      // Some mice scroll by lines or pages (Firefox's do), not points.
      const unit =
        event.deltaMode === WheelEvent.DOM_DELTA_LINE
          ? 16
          : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
            ? element.clientHeight
            : 1;
      const dx = event.deltaX * unit;
      const dy = event.deltaY * unit;
      // A trackpad pinch arrives as a wheel event with Ctrl held.
      if (event.ctrlKey || event.metaKey) {
        const [px, py] = point(event);
        change((view) => zoomAround(view, Math.exp(-dy * 0.01), px, py));
      } else {
        change((view) => ({ ...view, x: view.x - dx, y: view.y - dy }));
      }
    };
    let gestureScale = 1;
    const gestureStart = (event: Event) => {
      event.preventDefault();
      gestureScale = 1;
    };
    const gestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      const [px, py] = point(gesture);
      const factor = gesture.scale / gestureScale;
      gestureScale = gesture.scale;
      change((view) => zoomAround(view, factor, px, py));
    };
    element.addEventListener("wheel", wheel, { passive: false });
    element.addEventListener("gesturestart", gestureStart);
    element.addEventListener("gesturechange", gestureChange);
    return () => {
      element.removeEventListener("wheel", wheel);
      element.removeEventListener("gesturestart", gestureStart);
      element.removeEventListener("gesturechange", gestureChange);
    };
  }, [change]);

  // Dragging with one pointer pans; others are ignored. A drag that started on a tile doesn't also
  // select it.
  const press = useRef<{ pointer: number; x: number; y: number; moved: boolean } | null>(null);
  const onPointerDown = (event: React.PointerEvent) => {
    // A second finger isn't primary.
    if (event.button !== 0 || !event.isPrimary) return;
    const pointer = event.pointerId;
    press.current = { pointer, x: event.clientX, y: event.clientY, moved: false };
  };
  const onPointerMove = (event: React.PointerEvent) => {
    const current = press.current;
    if (current === null || event.pointerId !== current.pointer) return;
    // Released where the canvas didn't hear it, e.g. over the toolbar.
    if (event.buttons === 0) {
      press.current = null;
      setDragging(false);
      return;
    }
    const dx = event.clientX - current.x;
    const dy = event.clientY - current.y;
    if (!current.moved && Math.hypot(dx, dy) < dragThreshold) return;
    if (!current.moved) {
      current.moved = true;
      setDragging(true);
      event.currentTarget.setPointerCapture(event.pointerId);
    }
    press.current = { ...current, x: event.clientX, y: event.clientY };
    change((view) => ({ ...view, x: view.x + dx, y: view.y + dy }));
  };
  const onPointerUp = (event: React.PointerEvent) => {
    if (event.pointerId !== press.current?.pointer) return;
    setDragging(false);
    // Cleared after the click that follows, which checks it.
    setTimeout(() => (press.current = null));
  };
  const onClickCapture = (event: React.MouseEvent) => {
    if (press.current?.moved === true) event.stopPropagation();
  };

  return (
    <div
      ref={viewport}
      className={`absolute inset-0 touch-none overflow-hidden select-none ${dragging ? "cursor-grabbing" : "cursor-grab"}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      onClickCapture={onClickCapture}
    >
      <div
        ref={content}
        // Its own layer from the start, so the first pan doesn't promote it (851-2714).
        className="absolute top-0 left-0 origin-top-left will-change-transform"
        style={{ width, height, transform: transformOf(view) }}
      >
        <RegionContext value={stableRegion}>{children}</RegionContext>
      </div>
    </div>
  );
}
