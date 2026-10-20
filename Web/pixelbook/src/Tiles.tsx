// What the canvas shows in both modes: snapshot tiles and text labels.
import { createContext, useContext } from "react";
import { useNear } from "./Canvas.tsx";
import type { Label, Tile } from "./Grid.ts";
import { type Scheme, tileImageUrl } from "./Snapshots.ts";

export const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

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
}: {
  readonly tile: Tile;
  readonly onSelect: (tile: Tile) => void;
}) {
  const density = useContext(DensityContext);
  return (
    <button
      type="button"
      className={`tile ${tile.platform} ${tile.scheme}`}
      style={{ left: tile.x, top: tile.y, width: tile.width, height: tile.height }}
      title={`${tile.snapshot.screen}: ${tile.snapshot.state} (${schemeNames[tile.scheme]})`}
      onClick={() => onSelect(tile)}
    >
      {tile.change !== undefined && (
        <span className={`badge ${tile.change.label.toLowerCase()}`}>{tile.change.label}</span>
      )}
      <img
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

export function Labels({ labels }: { readonly labels: ReadonlyArray<Label> }) {
  const shown = useNear(labels, (label) => ({ x: label.x, y: label.y, ...labelExtent }));
  return shown.map((label) => (
    <div
      key={`${label.kind}/${label.x}/${label.y}`}
      className={`label ${label.kind}`}
      style={{ left: label.x, top: label.y }}
    >
      {label.text}
    </div>
  ));
}
