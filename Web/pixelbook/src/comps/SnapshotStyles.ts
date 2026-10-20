// Tailwind classes for snapshots, shared by the canvas, the inspector and the layers list.
import type { ChangeLabel } from "../lib/Grid.ts";
import type { Platform, Scheme } from "../lib/Snapshots.ts";

const snapshotBackgrounds = {
  macos: { light: "bg-mac-light", dark: "bg-mac-dark" },
  ios: { light: "bg-iphone-light", dark: "bg-iphone-dark" },
} as const;

/** What a snapshot is shown over: its platform's background in its appearance (the theme's). */
export const snapshotBackground = (platform: Platform, scheme: Scheme) =>
  snapshotBackgrounds[platform][scheme];

/** A comparison's badge colors, by its label: the canvas's, and the layers list's. */
export const badgeColors: Record<ChangeLabel, string> = {
  Before: "bg-secondary",
  After: "bg-added",
  New: "bg-added",
  Removed: "bg-removed",
};
