import { describe, expect, it } from "vite-plus/test";
import {
  fitView,
  intersects,
  maxZoom,
  needsRender,
  near,
  renderRegion,
  startView,
  zoomAround,
} from "../src/Canvas.tsx";

describe("canvas", () => {
  it("zooms around the pointer, within limits", () => {
    const view = { x: 100, y: 50, zoom: 0.5 };
    const zoomed = zoomAround(view, 2, 300, 250);
    // The canvas point under the pointer, (400, 400), stays under it.
    expect(zoomed).toEqual({ zoom: 1, x: -100, y: -150 });
    expect(zoomAround(view, 1000, 0, 0).zoom).toBe(maxZoom);
  });

  it("fits the canvas below the toolbar, at most at 100%", () => {
    expect(fitView(2000, 1000, 1000, 1064)).toEqual({ zoom: 0.5, x: 0, y: 64 + 250 });
    expect(fitView(100, 100, 1000, 1064).zoom).toBe(1);
  });

  it("starts at the top left, as wide as the viewport but readable", () => {
    expect(startView(2000, 1000)).toEqual({ zoom: 0.5, x: 0, y: 64 });
    // A wide canvas starts at the readable minimum rather than fitting.
    expect(startView(100_000, 1000)).toEqual({ zoom: 0.2, x: 0, y: 64 });
    expect(startView(500, 1000)).toEqual({ zoom: 1, x: 250, y: 64 });
  });

  it("renders what's in view and half a screen around it, snapped to cells", () => {
    // 1,000 × 800 points at 50%: 2,000 × 1,600 canvas points from (0, 0). Cells are 512.
    const region = renderRegion({ x: 0, y: 0, zoom: 0.5 }, 1000, 800);
    expect(region).toEqual({ x0: -1024, y0: -1024, x1: 3072, y1: 2560 });
    // Panning less than a cell doesn't change it.
    expect(renderRegion({ x: -20, y: -20, zoom: 0.5 }, 1000, 800)).toEqual(region);
    expect(intersects(region, { x: 3000, y: 0, width: 100, height: 100 })).toBe(true);
    expect(intersects(region, { x: 3072, y: 0, width: 100, height: 100 })).toBe(false);
    expect(intersects(region, { x: -1200, y: -1200, width: 200, height: 200 })).toBe(true);
  });

  it("keeps the items that reach into the region, or all of them without one", () => {
    const region = { x0: 0, y0: 0, x1: 100, y1: 100 };
    const items = [
      { x: 10, y: 10, width: 10, height: 10 },
      { x: 200, y: 10, width: 10, height: 10 },
    ];
    expect(near(region, items, (item) => item)).toEqual([items[0]]);
    expect(near(undefined, items, (item) => item)).toEqual(items);
  });

  it("renders a moved view when it zooms or reaches another region", () => {
    const viewport = { width: 1000, height: 800 };
    const view = { x: 0, y: 0, zoom: 0.5 };
    // Panning within a cell only moves the canvas.
    expect(needsRender({ ...view, x: -20 }, view, viewport)).toBe(false);
    // Past one, the region changes.
    expect(needsRender({ ...view, x: -400 }, view, viewport)).toBe(true);
    expect(needsRender({ ...view, zoom: 0.6 }, view, viewport)).toBe(true);
    // Without a viewport's size, only zooming does.
    expect(needsRender({ ...view, x: -400 }, view, undefined)).toBe(false);
  });
});
