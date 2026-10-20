// What the canvas shows in both modes: snapshot tiles and text labels.
import { createContext, useContext } from "react";
import { useNear } from "./Canvas.tsx";
import type { Label, Tile } from "./Grid.ts";
import { type Platform, type Scheme, tileImageUrl } from "./Snapshots.ts";

export const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

/** What a snapshot is shown over: its platform's background in its appearance (the theme's). */
export const snapshotBackground = (platform: Platform, scheme: Scheme) =>
  ({
    macos: { light: "bg-mac-light", dark: "bg-mac-dark" },
    ios: { light: "bg-iphone-light", dark: "bg-iphone-dark" },
  })[platform][scheme];

/** A comparison's badge colors, by its label. */
const badgeColors: Record<string, string> = {
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

/** A snapshot, at `tile`'s position in its container; clicking it opens it full size. */
export function TileButton({
  tile,
  onSelect,
  stacked = false,
}: {
  readonly tile: Tile;
  readonly onSelect: (tile: Tile) => void;
  /** Whether more states are stacked behind it, as on a flowchart node with several. */
  readonly stacked?: boolean;
}) {
  const density = useContext(DensityContext);
  return (
    <button
      type="button"
      className={[
        "absolute cursor-pointer overflow-hidden hover:outline-4 hover:outline-offset-4 hover:outline-accent focus-visible:outline-4 focus-visible:outline-offset-4 focus-visible:outline-accent",
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
          className={`absolute top-3 left-3 z-1 rounded-full px-3.5 py-1 text-[28px] font-bold text-white ${badgeColors[tile.change.label] ?? "bg-secondary"}`}
        >
          {tile.change.label}
        </span>
      )}
      <img
        className="block h-full w-full"
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

/**
 * Room for a label's text, which isn't measured, in points: an app's title (`.label.app`, 112
 * points) runs to about 1,500 points.
 */
const labelExtent = { width: 2000, height: 120 };

/** A label's type, by its kind: sized to read on the zoomed-out canvas. */
const labelStyles: Record<Label["kind"], string> = {
  app: "text-[112px] leading-none font-bold",
  screen: "text-[56px] leading-none font-semibold text-secondary",
  caption: "text-[28px] font-semibold text-secondary",
};

export function Labels({ labels }: { readonly labels: ReadonlyArray<Label> }) {
  const shown = useNear(labels, (label) => ({ x: label.x, y: label.y, ...labelExtent }));
  return shown.map((label) => (
    <div
      key={`${label.kind}/${label.x}/${label.y}`}
      className={`absolute whitespace-nowrap ${labelStyles[label.kind]}`}
      style={{ left: label.x, top: label.y }}
    >
      {label.text}
    </div>
  ));
}
