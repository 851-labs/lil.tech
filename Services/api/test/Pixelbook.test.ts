import { assert, describe, it } from "@effect/vitest";
import { deflateSync } from "node:zlib";
import { buildManifest, pngInfo, type RenderedImage, screenName } from "../scripts/pixelbook.ts";

describe("Pixelbook manifests", () => {
  it("names screens after their preview files", () => {
    assert.strictEqual(screenName("SyncStatusViewPreviews.swift"), "Sync Status");
    assert.strictEqual(screenName("AppView.swift"), "App");
    assert.strictEqual(screenName("AccountSheetPreviews.swift"), "Account Sheet");
    assert.strictEqual(screenName("HRVChart.swift"), "HRV Chart");
    assert.strictEqual(screenName("View.swift"), "View.swift");
  });

  it("groups each preview's appearances, in a stable order", () => {
    const image = (
      name: string,
      appearance: "light" | "dark",
      hash: string,
      line = 12,
    ): RenderedImage => ({
      name,
      appearance,
      sidecar: {
        display_name: name.split("_").at(-1) ?? name,
        group: "HealthMacApp/SyncStatusViewPreviews.swift",
        context: { preview: { line } },
      },
      variant: {
        image: `images/${hash}.png`,
        thumbnail: `thumbnails/${hash}.png`,
        width: 400,
        height: 300,
        scale: 2,
      },
    });
    const manifest = buildManifest("health-mac", "k", "c", [
      image("HealthMacApp_SyncStatusViewPreviews.swift_Syncing", "dark", "2"),
      image("HealthMacApp_SyncStatusViewPreviews.swift_Failed", "light", "3", 30),
      image("HealthMacApp_SyncStatusViewPreviews.swift_Syncing", "light", "1"),
    ]);
    assert.strictEqual(manifest.platform, "macos");
    assert.deepStrictEqual(
      manifest.snapshots.map(({ state, line, variants }) => ({
        state,
        line,
        light: variants.light?.image,
        dark: variants.dark?.image,
        darkThumbnail: variants.dark?.thumbnail,
      })),
      [
        {
          state: "Failed",
          line: 30,
          light: "images/3.png",
          dark: undefined,
          darkThumbnail: undefined,
        },
        {
          state: "Syncing",
          line: 12,
          light: "images/1.png",
          dark: "images/2.png",
          darkThumbnail: "thumbnails/2.png",
        },
      ],
    );
    const [first] = manifest.snapshots;
    assert.strictEqual(first?.module, "HealthMacApp");
    assert.strictEqual(first?.file, "SyncStatusViewPreviews.swift");
    assert.strictEqual(first?.screen, "Sync Status");
    assert.strictEqual(buildManifest("health-iphone", "k", "c", []).platform, "ios");
  });

  it("reads a PNG's size and scale", () => {
    const chunk = (type: string, data: Buffer) => {
      const length = Buffer.alloc(4);
      length.writeUInt32BE(data.length);
      // The CRC isn't checked.
      return Buffer.concat([length, Buffer.from(type, "latin1"), data, Buffer.alloc(4)]);
    };
    const header = Buffer.alloc(13);
    header.writeUInt32BE(1206, 0);
    header.writeUInt32BE(2622, 4);
    const physical = Buffer.alloc(9);
    // 216 dots per inch, in pixels per meter.
    physical.writeUInt32BE(8504, 0);
    physical.writeUInt32BE(8504, 4);
    physical[8] = 1;
    const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const png = (...chunks: Buffer[]) =>
      Buffer.concat([signature, chunk("IHDR", header), ...chunks, chunk("IEND", Buffer.alloc(0))]);
    const pixels = chunk("IDAT", deflateSync(Buffer.alloc(1)));
    assert.deepStrictEqual(pngInfo(png(chunk("pHYs", physical), pixels)), {
      width: 1206,
      height: 2622,
      scale: 3,
    });
    assert.strictEqual(pngInfo(png(pixels)).scale, 1);
  });
});
