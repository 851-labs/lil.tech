import { assert, describe, it } from "@effect/vitest";
import { deflateSync } from "node:zlib";
import {
  buildManifests,
  type CatalogInputs,
  type CatalogManifest,
  catalogStateLines,
  isCatalogManifest,
  parseCatalogManifest,
  pngInfo,
  thumbnail,
  type Variant,
} from "../scripts/pixelbook.ts";
import { decodePng, encodePng, shrink } from "../scripts/png.ts";

const folder = "LilPackage/Tests/HealthSnapshotTests/Catalogs/LilAuth";
const source = `${folder}/SignInCatalog.swift`;
const references = `${folder}/__Snapshots__/SignInCatalog`;

/** A screen's manifest, as its snapshot test writes it. */
const catalog = (app: string, screen: string, names: ReadonlyArray<string>): CatalogManifest => {
  const slug = (name: string) =>
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
  return {
    app,
    screen,
    catalog: "LilAuth/SignInCatalog.swift",
    states: names.map((name) => {
      const id = `${slug(screen)}.${slug(name)}`;
      return {
        id,
        name,
        source,
        light: `${references}/${id}-light.png`,
        dark: `${references}/${id}-dark.png`,
      };
    }),
  };
};

const variant = (hash: string): Variant => ({
  image: `images/${hash}.png`,
  thumbnail: `thumbnails/${hash}.png`,
  width: 768,
  height: 840,
  scale: 2,
});

describe("Pixelbook manifests", () => {
  it("finds catalog manifests beside their references", () => {
    assert.isTrue(isCatalogManifest(`${references}/sign-in-mac.json`));
    assert.isTrue(
      isCatalogManifest(
        "LilPackage/Tests/HealthSnapshotTests/Catalogs/HealthPages/__Snapshots__/SleepCatalog/sleep.json",
      ),
    );
    assert.isFalse(isCatalogManifest(`${references}/sign-in-mac.signed-out-light.png`));
    assert.isFalse(isCatalogManifest("Web/pixelbook/graphs/health-mac.json"));
    assert.isFalse(
      isCatalogManifest("LilPackage/Tests/HealthSnapshotTests/__Snapshots__/A/a.json"),
    );
  });

  it("reads a catalog manifest, or says what's wrong with it", () => {
    const manifest = catalog("health-mac", "Sign In (Mac)", ["Signed out"]);
    assert.deepStrictEqual(parseCatalogManifest(JSON.parse(JSON.stringify(manifest))), manifest);
    assert.deepStrictEqual(parseCatalogManifest({ ...manifest, app: 1 }), {
      problem: `its "app" isn't a string`,
    });
    assert.deepStrictEqual(parseCatalogManifest({ ...manifest, states: [{ name: "A" }] }), {
      problem: "a state isn't an id, name, source, light and dark",
    });
  });

  it("finds each state's line, as #line gives it, skipping comments", () => {
    const swift = [
      "let catalog = StateCatalog(", // 1
      '  "Sign In", states: shared + [', // 2
      '    // CatalogState("Old") { a },', // 3
      '    CatalogState("Apple\'s page") { b },', // 4
      '    /* CatalogState("Older")', // 5
      "    */", // 6
      "  ])", // 7
      "let shared = [", // 8
      "  CatalogState(", // 9
      '    "Say \\"hi\\"", minHeight: 400', // 10
      "  ) { c },", // 11
      '  CatalogState("Apple\'s page") { d },', // 12
      "]",
    ].join("\n");
    assert.deepStrictEqual(
      [...catalogStateLines(swift)],
      [
        ["Apple's page", 4],
        ['Say "hi"', 9],
      ],
    );
  });

  it("builds each app's manifest from its catalogs, in their order", () => {
    const mac = catalog("health-mac", "Sign In (Mac)", ["Signed out", "Apple's page"]);
    const phone = catalog("health-iphone", "Sign In (iPhone)", ["Signed out"]);
    const images = new Map<string, Variant>();
    for (const [index, state] of [...mac.states, ...phone.states].entries()) {
      images.set(state.light, variant(`l${index}`));
      images.set(state.dark, variant(`d${index}`));
    }
    const inputs: CatalogInputs = {
      catalogs: [
        { path: `${references}/sign-in-mac.json`, manifest: mac },
        { path: `${references}/sign-in-iphone.json`, manifest: phone },
      ],
      // "Apple's page" is written before the shared states, but comes after them.
      sources: new Map([
        [source, 'CatalogState("Apple\'s page") {}\nlet shared = [CatalogState("Signed out") {}]'],
      ]),
      images,
    };
    const { manifests, warnings } = buildManifests("k", "c", inputs);
    assert.deepStrictEqual(warnings, []);
    assert.deepStrictEqual(
      manifests.map(({ app, platform, key, commit }) => ({ app, platform, key, commit })),
      [
        { app: "health-iphone", platform: "ios", key: "k", commit: "c" },
        { app: "health-mac", platform: "macos", key: "k", commit: "c" },
      ],
    );
    assert.deepStrictEqual(manifests[1]?.snapshots, [
      {
        id: "sign-in-mac.signed-out",
        module: "LilAuth",
        file: "SignInCatalog.swift",
        path: source,
        line: 2,
        order: 0,
        screen: "Sign In (Mac)",
        state: "Signed out",
        variants: { light: variant("l0"), dark: variant("d0") },
      },
      {
        id: "sign-in-mac.apple-s-page",
        module: "LilAuth",
        file: "SignInCatalog.swift",
        path: source,
        line: 1,
        order: 1,
        screen: "Sign In (Mac)",
        state: "Apple's page",
        variants: { light: variant("l1"), dark: variant("d1") },
      },
    ]);
  });

  it("leaves out what's missing, and says so", () => {
    const mac = catalog("health-mac", "Sign In", ["Signed out", "Failed", "Gone"]);
    const [signedOut, failed] = mac.states;
    const images = new Map<string, Variant>([
      [signedOut?.light ?? "", variant("1")],
      [signedOut?.dark ?? "", variant("2")],
      [failed?.light ?? "", variant("3")],
    ]);
    const leftBehind = { ...mac, catalog: "LilAuth/OldCatalog.swift", screen: "Old" };
    const { manifests, warnings } = buildManifests("k", "c", {
      catalogs: [
        { path: `${references}/sign-in.json`, manifest: mac },
        {
          path: `${folder}/__Snapshots__/OldCatalog/old.json`,
          manifest: {
            ...leftBehind,
            states: leftBehind.states.map((s) => ({ ...s, source: `${folder}/OldCatalog.swift` })),
          },
        },
      ],
      sources: new Map([[source, ""]]),
      images,
    });
    // Without a line, but with what it has.
    assert.deepStrictEqual(
      manifests[0]?.snapshots.map(({ state, line, variants }) => ({
        state,
        line,
        light: variants.light?.image,
        dark: variants.dark?.image,
      })),
      [
        { state: "Signed out", line: null, light: "images/1.png", dark: "images/2.png" },
        { state: "Failed", line: null, light: "images/3.png", dark: undefined },
      ],
    );
    assert.deepStrictEqual(warnings, [
      `${folder}/__Snapshots__/OldCatalog/old.json is left out: ${folder}/OldCatalog.swift doesn't exist. Delete it?`,
      `Sign In: "Failed" has no reference ${failed?.dark}.`,
      `Sign In: "Gone" has no reference ${mac.states[2]?.light}.`,
      `Sign In: "Gone" has no reference ${mac.states[2]?.dark}.`,
    ]);
  });
});

describe("Pixelbook's PNGs", () => {
  const chunk = (type: string, data: Buffer) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    // The CRC isn't checked.
    return Buffer.concat([length, Buffer.from(type, "latin1"), data, Buffer.alloc(4)]);
  };
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const header = (width: number, height: number, colorType = 6) => {
    const data = Buffer.alloc(13);
    data.writeUInt32BE(width, 0);
    data.writeUInt32BE(height, 4);
    data.set([8, colorType, 0, 0, 0], 8);
    return chunk("IHDR", data);
  };
  const png = (...chunks: Buffer[]) =>
    Buffer.concat([signature, ...chunks, chunk("IEND", Buffer.alloc(0))]);

  it("reads a PNG's size and scale", () => {
    const physical = Buffer.alloc(9);
    // 216 dots per inch, in pixels per meter.
    physical.writeUInt32BE(8504, 0);
    physical.writeUInt32BE(8504, 4);
    physical[8] = 1;
    const pixels = chunk("IDAT", deflateSync(Buffer.alloc(1)));
    assert.deepStrictEqual(pngInfo(png(header(1206, 2622), chunk("pHYs", physical), pixels)), {
      width: 1206,
      height: 2622,
      scale: 3,
    });
    assert.strictEqual(pngInfo(png(header(1206, 2622), pixels)).scale, 1);
  });

  it("decodes every row filter", () => {
    // A 2×5 RGB image, one row per filter (none, sub, up, average, Paeth), all from the same
    // pixels: [10, 20, 30] and [40, 50, 60].
    const plain = [10, 20, 30, 40, 50, 60];
    const rows = [
      [0, ...plain],
      [1, 10, 20, 30, 30, 30, 30],
      [2, 0, 0, 0, 0, 0, 0],
      // Average: left + up >> 1. First pixel: up only (10 >> 1 = 5).
      [3, 5, 10, 15, 40 - ((10 + 40) >> 1), 50 - ((20 + 50) >> 1), 60 - ((30 + 60) >> 1)],
      // Paeth: up for the first pixel; for the second, up (40) is nearest.
      [4, 0, 0, 0, 0, 0, 0],
    ];
    const decoded = decodePng(
      png(header(2, 5, 2), chunk("IDAT", deflateSync(Buffer.from(rows.flat())))),
    );
    const rgba = [10, 20, 30, 255, 40, 50, 60, 255];
    assert.deepStrictEqual([...decoded.data], Array.from({ length: 5 }, () => rgba).flat());
    assert.throws(() => decodePng(png(header(1, 1, 3))), /Only 8-bit RGBA or RGB/);
  });

  it("shrinks by averaging, weighted by alpha, and encodes what it decodes", () => {
    // 4×4: a red half, opaque, and a transparent green half that mustn't tint it.
    const data = new Uint8Array(4 * 4 * 4);
    for (let pixel = 0; pixel < 16; pixel++) {
      const red = pixel % 4 < 2;
      data.set(red ? [255, 0, 0, 255] : [0, 255, 0, 0], pixel * 4);
    }
    const small = shrink({ width: 4, height: 4, data }, 4);
    assert.deepStrictEqual(
      { ...small, data: [...small.data] },
      {
        width: 1,
        height: 1,
        data: [255, 0, 0, 128],
      },
    );
    const image = { width: 4, height: 4, data };
    const roundTrip = decodePng(encodePng(image));
    assert.deepStrictEqual(
      { ...roundTrip, data: [...roundTrip.data] },
      { ...image, data: [...data] },
    );
    // 9×5 → 2×1, rounded.
    const thumb = decodePng(
      thumbnail(encodePng({ width: 9, height: 5, data: new Uint8Array(180) })),
    );
    assert.deepStrictEqual([thumb.width, thumb.height], [2, 1]);
  });
});
