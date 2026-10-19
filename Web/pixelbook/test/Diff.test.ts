import { describe, expect, it } from "vite-plus/test";
import { comment, marker } from "../scripts/diff.ts";
import { diffBooks, layoutDiff, summarize } from "../src/Diff.ts";
import { noFilters, spacing } from "../src/Grid.ts";
import type { Book, Manifest, Snapshot } from "../src/Snapshots.ts";

const snapshot = (screen: string, state: string, light: string, dark?: string): Snapshot => ({
  id: `${screen}_${state}`,
  module: "HealthMacApp",
  file: `${screen}Previews.swift`,
  line: 1,
  screen,
  state,
  variants: {
    light: { image: `images/${light}.png`, width: 800, height: 600, scale: 2 },
    ...(dark === undefined
      ? {}
      : { dark: { image: `images/${dark}.png`, width: 800, height: 600, scale: 2 } }),
  },
});

const book = (commit: string, snapshots: ReadonlyArray<Snapshot>): Book => {
  const manifest: Manifest = {
    version: 1,
    app: "health-mac",
    platform: "macos",
    key: commit,
    commit,
    snapshots,
  };
  return { key: commit, commit, manifests: [manifest] };
};

const base = book("base", [
  snapshot("Summary", "Pinned", "a", "b"),
  snapshot("Summary", "Loading", "c", "d"),
  snapshot("Account", "Export", "e"),
]);
const head = book("head", [
  // The dark image changed.
  snapshot("Summary", "Pinned", "a", "b2"),
  snapshot("Summary", "Loading", "c", "d"),
  snapshot("Sleep", "Night", "f"),
]);

describe("comparing snapshots", () => {
  it("finds changed, added and removed snapshots by their images", () => {
    const changes = diffBooks(base, head);
    expect(
      changes.map(({ kind, schemes, after, before }) => [kind, (after ?? before)?.id, schemes]),
    ).toEqual([
      ["removed", "Account_Export", ["light"]],
      ["added", "Sleep_Night", ["light"]],
      ["changed", "Summary_Pinned", ["dark"]],
    ]);
    expect(summarize(changes)).toEqual({ changed: 1, added: 1, removed: 1, screens: 3 });
  });

  it("finds nothing when nothing changed", () => {
    expect(diffBooks(base, base)).toEqual([]);
  });

  it("lays a change out before and after, close together", () => {
    const layout = layoutDiff(diffBooks(base, head), noFilters);
    const summary = layout.tiles.filter((tile) => tile.snapshot.screen === "Summary");
    expect(summary.map((tile) => [tile.change?.label, tile.variant.image])).toEqual([
      ["Before", "images/b.png"],
      ["After", "images/b2.png"],
    ]);
    expect(summary[0]?.change?.other?.image).toBe("images/b2.png");
    expect((summary[1]?.x ?? 0) - (summary[0]?.x ?? 0)).toBe(400 + spacing.scheme);
    expect(layout.labels.map((label) => label.text)).toEqual([
      "lil health for Mac",
      "Account",
      "Sleep",
      "Summary",
    ]);
  });

  it("leaves out appearances the filters hide", () => {
    const layout = layoutDiff(diffBooks(base, head), { ...noFilters, schemes: ["light"] });
    // The only change on Summary is dark.
    expect(layout.labels.map((label) => label.text)).not.toContain("Summary");
  });
});

describe("the PR comment", () => {
  const sha = (c: string) => c.repeat(40);

  it("counts what changed and links the comparison", () => {
    const text = comment(sha("a"), sha("b"), { base, head });
    expect(text.startsWith(marker)).toBe(true);
    expect(text).toContain("1 changed, 1 new, 1 removed on 3 screens since aaaaaaa");
    expect(text).toContain(`https://pixelbook.lil.tech/?commit=${sha("b")}&base=${sha("a")}`);
  });

  it("says when nothing changed, or a side isn't published", () => {
    expect(comment(sha("a"), sha("b"), { base, head: base })).toContain("no snapshots changed");
    expect(comment(sha("a"), sha("b"), { base, head: undefined })).toContain(
      "no snapshots of bbbbbbb yet",
    );
    expect(comment(sha("a"), sha("b"), { base: undefined, head })).toContain(
      "no snapshots of the base, aaaaaaa",
    );
  });
});
