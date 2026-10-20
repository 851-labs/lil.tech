import { describe, expect, it } from "vite-plus/test";
import { fitView, maxZoom, startView, zoomAround } from "../src/lib/View.ts";

describe("view", () => {
  it("zooms around the pointer, within limits", () => {
    const view = { x: 100, y: 50, zoom: 0.5 };
    const zoomed = zoomAround(view, 2, 300, 250);
    // The canvas point under the pointer, (400, 400), stays under it.
    expect(zoomed).toEqual({ zoom: 1, x: -100, y: -150 });
    expect(zoomAround(view, 1000, 0, 0).zoom).toBe(maxZoom);
  });

  it("fits the canvas in its viewport, at most at 100%", () => {
    expect(fitView(2000, 1000, 1000, 1000)).toEqual({ zoom: 0.5, x: 0, y: 250 });
    expect(fitView(100, 100, 1000, 1000).zoom).toBe(1);
  });

  it("starts at the top left, as wide as the viewport but readable", () => {
    expect(startView(2000, 1000)).toEqual({ zoom: 0.5, x: 0, y: 0 });
    // A wide canvas starts at the readable minimum rather than fitting.
    expect(startView(100_000, 1000)).toEqual({ zoom: 0.2, x: 0, y: 0 });
    expect(startView(500, 1000)).toEqual({ zoom: 1, x: 250, y: 0 });
  });
});
