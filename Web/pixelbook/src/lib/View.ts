// The canvas's view: where it's panned to and how far it's zoomed, and the views it moves to.

export interface View {
  readonly x: number;
  readonly y: number;
  readonly zoom: number;
}

export const minZoom = 0.02;
export const maxZoom = 4;

export const clampZoom = (zoom: number) => Math.min(maxZoom, Math.max(minZoom, zoom));

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
