// What the canvas shows in both modes: snapshot tiles and text labels.
import { createContext, useContext } from "react";
import type { Label, Tile } from "./Grid.ts";
import { imageUrl, type Scheme, thumbnailUrl } from "./Snapshots.ts";

export const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

/**
 * Whether tiles show thumbnails rather than full images: zoomed out, so the canvas doesn't load
 * and decode every image at full size (851-2712). A context, so crossing the threshold re-renders
 * the tiles but not the memoized layouts around them.
 */
export const ThumbnailsContext = createContext(true);

/** A snapshot, at `tile`'s position in its container; clicking it opens it full size. */
export function TileButton({
  tile,
  onSelect,
}: {
  readonly tile: Tile;
  readonly onSelect: (tile: Tile) => void;
}) {
  const thumbnails = useContext(ThumbnailsContext);
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
        src={thumbnails ? thumbnailUrl(tile.variant) : imageUrl(tile.variant)}
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

export function Labels({ labels }: { readonly labels: ReadonlyArray<Label> }) {
  return labels.map((label) => (
    <div
      key={`${label.kind}/${label.x}/${label.y}`}
      className={`label ${label.kind}`}
      style={{ left: label.x, top: label.y }}
    >
      {label.text}
    </div>
  ));
}
