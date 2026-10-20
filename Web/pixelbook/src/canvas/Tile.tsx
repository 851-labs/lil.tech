// The canvas's snapshot tiles, in both modes: the grid's, and the flowchart's screens'.
import type { NodeProps } from "@xyflow/react";
import { createContext, useContext } from "react";
import type { TileNode } from "../lib/Elements.ts";
import { type ChangeLabel, type Tile, tileId } from "../lib/Grid.ts";
import { type Platform, type Scheme, schemeNames, tileImageUrl } from "../lib/Snapshots.ts";

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

/**
 * Screen pixels per point tiles are drawn at (`tileDensity`), so that zoomed out they show
 * thumbnails rather than load and decode every image at full size (851-2712). `undefined` until
 * the canvas knows its view, so tiles don't load a thumbnail and then the image. A context, so a
 * change re-renders the tiles but not the memoized layouts around them. Outside one, full images.
 */
export const DensityContext = createContext<number | undefined>(Number.POSITIVE_INFINITY);

/** What clicking a tile does: open it. A context, so the canvas's nodes don't carry it. */
export const SelectContext = createContext<(tile: Tile) => void>(() => {});

/** The selected tile's ID (`tileId`), which tiles outline. */
export const SelectedContext = createContext<string | undefined>(undefined);

/** A snapshot, at `tile`'s position in its container; clicking it opens it full size. */
export function TileButton({
  tile,
  stacked = false,
}: {
  readonly tile: Tile;
  /** Whether more states are stacked behind it, as on a flowchart node with several. */
  readonly stacked?: boolean;
}) {
  const density = useContext(DensityContext);
  const onSelect = useContext(SelectContext);
  const selected = useContext(SelectedContext) === tileId(tile);
  return (
    <button
      type="button"
      className={[
        // React Flow's nodes don't take pointer events when they can't be selected or dragged.
        "pointer-events-auto absolute cursor-pointer overflow-hidden",
        // Outlined when selected, and lighter when hovered or focused, as in Figma: 2 screen pixels
        // at any zoom (`--zoom`, which the page sets).
        selected
          ? "outline-[length:calc(2px/var(--zoom,1))] outline-offset-[calc(3px/var(--zoom,1))] outline-accent"
          : "hover:outline-[length:calc(2px/var(--zoom,1))] hover:outline-offset-[calc(3px/var(--zoom,1))] hover:outline-accent/40 focus-visible:outline-[length:calc(2px/var(--zoom,1))] focus-visible:outline-offset-[calc(3px/var(--zoom,1))] focus-visible:outline-accent/40",
        tile.platform === "ios" ? "rounded-[28px]" : "rounded-[10px]",
        stacked
          ? "shadow-[0_0_0_1px_var(--color-border),14px_14px_0_-2px_var(--color-stack-1),28px_28px_0_-4px_var(--color-stack-2)]"
          : "shadow-[0_0_0_1px_var(--color-border),0_8px_24px_rgb(0_0_0/0.12)]",
        snapshotBackground(tile.platform, tile.scheme),
      ].join(" ")}
      style={{ left: tile.x, top: tile.y, width: tile.width, height: tile.height }}
      title={`${tile.snapshot.screen}: ${tile.snapshot.state} (${schemeNames[tile.scheme]})`}
      aria-pressed={selected}
      onClick={() => onSelect(tile)}
    >
      {tile.change !== undefined && (
        <span
          className={`absolute top-3 left-3 z-1 rounded-full px-3.5 py-1 text-[28px] font-bold text-white ${badgeColors[tile.change.label]}`}
        >
          {tile.change.label}
        </span>
      )}
      <img
        className="h-full w-full"
        src={density === undefined ? undefined : tileImageUrl(tile.variant, density)}
        alt={`${tile.snapshot.screen}: ${tile.snapshot.state}`}
        width={tile.width}
        height={tile.height}
        loading="lazy"
        decoding="async"
        draggable={false}
      />
    </button>
  );
}

/** A tile on the canvas: its node is at its position. */
export function TileNodeView({ data }: NodeProps<TileNode>) {
  return <TileButton tile={{ ...data.tile, x: 0, y: 0 }} />;
}
