import { describe, expect, it } from "vite-plus/test";
import { layoutGrid, noFilters, spacing } from "../src/lib/Grid.ts";
import type { Manifest, Snapshot, Variant } from "../src/lib/Snapshots.ts";

const variant = (image: string, width: number, height: number, scale: number): Variant => ({
  image: `images/${image}.png`,
  width,
  height,
  scale,
});

const snapshot = (
  screen: string,
  state: string,
  line: number,
  variants: Snapshot["variants"],
): Snapshot => ({
  id: `${screen}_${state}`,
  module: "HealthMacApp",
  file: `${screen.replace(" ", "")}Previews.swift`,
  line,
  screen,
  state,
  variants,
});

const mac: Manifest = {
  version: 1,
  app: "health-mac",
  platform: "macos",
  key: "k",
  commit: "c",
  snapshots: [
    snapshot("Sync Status", "Failed", 30, {
      light: variant("a", 800, 400, 2),
      dark: variant("b", 800, 400, 2),
    }),
    snapshot("Sync Status", "Syncing", 12, {
      light: variant("c", 800, 600, 2),
      dark: variant("d", 800, 600, 2),
    }),
    snapshot("Account", "Signed in", 5, { light: variant("e", 600, 300, 2) }),
  ],
};

const phone: Manifest = {
  ...mac,
  app: "health-iphone",
  platform: "ios",
  snapshots: [snapshot("App", "Home", 1, { light: variant("f", 1206, 2622, 3) })],
};

describe("grid layout", () => {
  it("puts apps in sections, screens in rows, and states in source order", () => {
    const layout = layoutGrid([mac, phone], noFilters);
    expect(layout.labels.map(({ kind, text }) => `${kind}: ${text}`)).toEqual([
      "app: lil health for iPhone",
      "screen: App",
      "app: lil health for Mac",
      "screen: Account",
      "screen: Sync Status",
    ]);
    const syncStatus = layout.tiles.filter((tile) => tile.snapshot.screen === "Sync Status");
    expect(syncStatus.map((tile) => `${tile.snapshot.state} ${tile.scheme}`)).toEqual([
      "Syncing light",
      "Syncing dark",
      "Failed light",
      "Failed dark",
    ]);
    // Point sizes, a state's schemes close together, and states further apart.
    const [first, second, third] = syncStatus;
    expect(first).toMatchObject({ x: spacing.margin, width: 400, height: 300 });
    expect(second?.x).toBe(spacing.margin + 400 + spacing.scheme);
    expect(third?.x).toBe(spacing.margin + 800 + spacing.scheme + spacing.tile);
    // The iPhone at 3x.
    expect(layout.tiles[0]).toMatchObject({ width: 402, height: 874 });
  });

  it("stacks rows below the tallest tile of the row above", () => {
    const layout = layoutGrid([mac], noFilters);
    const account = layout.tiles.find((tile) => tile.snapshot.screen === "Account");
    const syncStatus = layout.labels.find((label) => label.text === "Sync Status");
    expect(syncStatus?.y).toBe((account?.y ?? 0) + 150 + spacing.row);
    expect(layout.height).toBe((syncStatus?.y ?? 0) + spacing.screenLabel + 300 + spacing.margin);
  });

  it("filters by app, platform and color scheme", () => {
    const dark = layoutGrid([mac, phone], { ...noFilters, schemes: ["dark"] });
    expect(dark.tiles.map((tile) => tile.variant.image)).toEqual(["images/d.png", "images/b.png"]);
    // Screens and apps with nothing to show are left out.
    expect(dark.labels.map(({ text }) => text)).toEqual(["lil health for Mac", "Sync Status"]);
    // Without a gap where the light-only state was.
    expect(dark.tiles[1]?.x).toBe(spacing.margin + 400 + spacing.tile);
    const ios = layoutGrid([mac, phone], { ...noFilters, platforms: ["ios"] });
    expect(ios.tiles.map((tile) => tile.app)).toEqual(["health-iphone"]);
    const app = layoutGrid([mac, phone], { ...noFilters, apps: ["health-mac"] });
    expect(new Set(app.tiles.map((tile) => tile.app))).toEqual(new Set(["health-mac"]));
  });
});
