import { describe, expect, it } from "vite-plus/test";
import { assetsUrl, tileDensity, tileImageUrl } from "../src/Snapshots.ts";

describe("tile images", () => {
  const variant = (scale: number, thumbnail?: string) => ({
    image: "images/a.png",
    ...(thumbnail === undefined ? {} : { thumbnail }),
    width: 400,
    height: 300,
    scale,
  });

  it("rounds the density up to a quarter, up to 1", () => {
    expect(tileDensity(0.1, 2)).toBe(0.25);
    expect(tileDensity(0.25, 2)).toBe(0.5);
    expect(tileDensity(0.26, 2)).toBe(0.75);
    expect(tileDensity(3, 2)).toBe(1);
  });

  it("shows a thumbnail while it holds enough pixels per point", () => {
    const mac = variant(2, "thumbnails/a.png");
    expect(tileImageUrl(mac, 0.5)).toBe(`${assetsUrl}/thumbnails/a.png`);
    expect(tileImageUrl(mac, 0.75)).toBe(`${assetsUrl}/images/a.png`);
    // An iPhone's 3x thumbnail holds 0.75 pixels per point.
    expect(tileImageUrl(variant(3, "thumbnails/a.png"), 0.75)).toBe(
      `${assetsUrl}/thumbnails/a.png`,
    );
    // A 1x image's thumbnail holds a quarter.
    expect(tileImageUrl(variant(1, "thumbnails/a.png"), 0.5)).toBe(`${assetsUrl}/images/a.png`);
  });

  it("shows the image when there's no thumbnail, or the density isn't known", () => {
    expect(tileImageUrl(variant(2), 0.25)).toBe(`${assetsUrl}/images/a.png`);
    expect(tileImageUrl(variant(2, "thumbnails/a.png"), Number.POSITIVE_INFINITY)).toBe(
      `${assetsUrl}/images/a.png`,
    );
  });
});
