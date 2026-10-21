import { describe, expect, it } from "vite-plus/test";
import type { FlowLayout, FlowNode } from "../src/lib/Flow.ts";
import type { Tile } from "../src/lib/Grid.ts";
import {
  type Frame,
  flowFrames,
  frameOf,
  frameToward,
  gridFrames,
  neighbor,
  steppedTile,
} from "../src/lib/Selection.ts";
import type { Snapshot } from "../src/lib/Snapshots.ts";

const tile = (id: string, x: number, y: number, width = 400, height = 300): Tile => {
  const variant = { image: `images/${id}.png`, width: width * 2, height: height * 2, scale: 2 };
  const snapshot: Snapshot = {
    id,
    module: "HealthMacApp",
    file: "SummaryPreviews.swift",
    line: 1,
    screen: "Summary",
    state: id,
    variants: { light: variant },
  };
  return {
    app: "health-mac",
    platform: "macos",
    snapshot,
    scheme: "light",
    variant,
    x,
    y,
    width,
    height,
  };
};

// Two rows: three tiles, then two, the second row's offset to the right.
const frames = gridFrames([
  tile("a", 0, 0),
  tile("b", 440, 0),
  tile("c", 880, 0),
  tile("d", 300, 400),
  tile("e", 740, 400),
]);
const named = (name: string) => frames.find((frame) => frame.tile.snapshot.id === name) as Frame;
const step = (from: string, direction: "left" | "right" | "up" | "down") =>
  neighbor(frames, named(from), direction)?.tile.snapshot.id;

describe("selection", () => {
  it("moves along a row, and stops at its end", () => {
    expect(step("a", "right")).toBe("b");
    expect(step("b", "right")).toBe("c");
    expect(step("b", "left")).toBe("a");
    expect(step("a", "left")).toBeUndefined();
  });

  it("moves between rows to the nearest frame across", () => {
    expect(step("b", "down")).toBe("d");
    expect(step("c", "down")).toBe("e");
    expect(step("e", "up")).toBe("c");
    expect(step("d", "up")).toBe("b");
    expect(step("d", "down")).toBeUndefined();
  });

  it("selects a flowchart screen by any of its states, showing the one it's stepped to", () => {
    const screen: FlowNode = {
      key: "health-mac/summary",
      title: "Summary",
      tiles: [tile("Loading", 0, 0), tile("Loaded", 0, 0, 400, 600)],
      x: 100,
      y: 50,
      width: 400,
      height: 412,
    };
    const layout: FlowLayout = {
      nodes: [screen, { ...screen, key: "health-mac/empty", tiles: [] }],
      edges: [],
      labels: [],
      unlinked: [tile("Export", 0, 1000)],
      width: 1000,
      height: 1400,
    };
    const flow = flowFrames(layout, new Map([[screen.key, 3]]));
    // The screen without states has no frame.
    expect(flow.map((frame) => frame.tile.snapshot.id)).toEqual(["Loaded", "Export"]);
    expect(flow[0]?.box).toEqual({ x: 100, y: 50 + 112, width: 400, height: 600 });
    expect(frameOf(flow, "health-mac/Loading/light")).toBe(flow[0]);
    expect(frameOf(flow, undefined)).toBeUndefined();
  });

  it("follows the flowchart's routes right and left, to the nearest screen at their other ends", () => {
    const at = (key: string, x: number, y: number): FlowNode => ({
      key,
      title: key,
      tiles: [tile(key, 0, 0)],
      x,
      y,
      width: 400,
      height: 412,
    });
    const route = (from: string, to: string) => ({
      from,
      to,
      label: undefined,
      points: [],
      labelAt: undefined,
    });
    const layout: FlowLayout = {
      // A launch screen leads to sign-in (above it) and consent (level, but further).
      nodes: [at("launch", 0, 400), at("sign-in", 600, 0), at("consent", 1400, 420)],
      edges: [route("launch", "sign-in"), route("launch", "consent"), route("sign-in", "consent")],
      labels: [],
      unlinked: [],
      width: 2000,
      height: 1000,
    };
    const flow = flowFrames(layout, new Map());
    const go = (from: string, direction: "left" | "right" | "up" | "down") =>
      neighbor(flow, flow.find((frame) => frame.key === from) as Frame, direction)?.key;
    expect(go("launch", "right")).toBe("sign-in");
    expect(go("sign-in", "right")).toBe("consent");
    expect(go("consent", "left")).toBe("sign-in");
    // Without routes that way, the nearest frame.
    expect(go("launch", "left")).toBeUndefined();
    expect(go("consent", "up")).toBe("sign-in");
  });

  it("selects the first frame when nothing is, and otherwise the neighbor that way", () => {
    expect(frameToward(frames, undefined, "left")?.tile.snapshot.id).toBe("a");
    expect(frameToward(frames, named("a"), "right")?.tile.snapshot.id).toBe("b");
    expect(frameToward(frames, named("a"), "left")).toBeUndefined();
    expect(frameToward([], undefined, "down")).toBeUndefined();
  });

  it("selects the state a flowchart screen steps to, if one of its states is selected", () => {
    const screen: FlowNode = {
      key: "health-mac/summary",
      title: "Summary",
      tiles: [tile("Loading", 0, 0), tile("Loaded", 0, 0), tile("Failed", 0, 0)],
      x: 0,
      y: 0,
      width: 400,
      height: 412,
    };
    const layout: FlowLayout = {
      nodes: [screen, { ...screen, key: "health-mac/empty", tiles: [] }],
      edges: [],
      labels: [],
      unlinked: [],
      width: 400,
      height: 412,
    };
    const stepped = (key: string, to: number, selected: string | undefined) =>
      steppedTile(layout, key, to, selected)?.snapshot.id;
    expect(stepped(screen.key, 1, "health-mac/Loading/light")).toBe("Loaded");
    // Wrapped around its states.
    expect(stepped(screen.key, 5, "health-mac/Loaded/light")).toBe("Failed");
    // Another screen's selected, or none.
    expect(stepped(screen.key, 1, "health-mac/Other/light")).toBeUndefined();
    expect(stepped(screen.key, 1, undefined)).toBeUndefined();
    // Not a screen, or one without states.
    expect(stepped("health-mac/nothing", 1, "health-mac/Loading/light")).toBeUndefined();
    expect(stepped("health-mac/empty", 1, "health-mac/Loading/light")).toBeUndefined();
    expect(steppedTile(undefined, screen.key, 1, "health-mac/Loading/light")).toBeUndefined();
  });
});
