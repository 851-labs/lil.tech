// What the canvas shows in both modes: snapshot tiles and text labels.
import type { NodeProps } from "@xyflow/react";
import { createContext, useContext } from "react";
import type { LabelNode, TileNode } from "./Elements.ts";
import type { ChangeLabel, Label, Tile } from "./Grid.ts";
import { type Platform, type Scheme, tileImageUrl } from "./Snapshots.ts";

export const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

const snapshotBackgrounds = {
  macos: { light: "bg-mac-light", dark: "bg-mac-dark" },
  ios: { light: "bg-iphone-light", dark: "bg-iphone-dark" },
} as const;

/** What a snapshot is shown over: its platform's background in its appearance (the theme's). */
export const snapshotBackground = (platform: Platform, scheme: Scheme) =>
  snapshotBackgrounds[platform][scheme];

/** A comparison's badge colors, by its label. */
const badgeColors: Record<ChangeLabel, string> = {
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
  return (
    <button
      type="button"
      className={[
        // React Flow's nodes don't take pointer events when they can't be selected or dragged.
        "pointer-events-auto absolute cursor-pointer overflow-hidden hover:outline-4 hover:outline-offset-4 hover:outline-accent focus-visible:outline-4 focus-visible:outline-offset-4 focus-visible:outline-accent",
        tile.platform === "ios" ? "rounded-[28px]" : "rounded-[10px]",
        stacked
          ? "shadow-[0_0_0_1px_var(--color-border),14px_14px_0_-2px_var(--color-stack-1),28px_28px_0_-4px_var(--color-stack-2)]"
          : "shadow-[0_0_0_1px_var(--color-border),0_8px_24px_rgb(0_0_0/0.12)]",
        snapshotBackground(tile.platform, tile.scheme),
      ].join(" ")}
      style={{ left: tile.x, top: tile.y, width: tile.width, height: tile.height }}
      title={`${tile.snapshot.screen}: ${tile.snapshot.state} (${schemeNames[tile.scheme]})`}
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

/** A label's type, by its kind: sized to read on the zoomed-out canvas. */
const labelStyles: Record<Label["kind"], string> = {
  app: "text-[112px] leading-none font-bold",
  screen: "text-[56px] leading-none font-semibold text-secondary",
  caption: "text-[28px] font-semibold text-secondary",
};

export function LabelNodeView({ data: { label } }: NodeProps<LabelNode>) {
  return <div className={`whitespace-nowrap ${labelStyles[label.kind]}`}>{label.text}</div>;
}
