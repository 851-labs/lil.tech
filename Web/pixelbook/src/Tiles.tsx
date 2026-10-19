// What the canvas shows in both modes: snapshot tiles and text labels.
import type { Label, Tile } from "./Grid.ts";
import { imageUrl, type Scheme } from "./Snapshots.ts";

export const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

/** A snapshot, at `tile`'s position in its container; clicking it opens it full size. */
export function TileButton({
  tile,
  onSelect,
}: {
  readonly tile: Tile;
  readonly onSelect: (tile: Tile) => void;
}) {
  return (
    <button
      type="button"
      className={`tile ${tile.platform} ${tile.scheme}`}
      style={{ left: tile.x, top: tile.y, width: tile.width, height: tile.height }}
      title={`${tile.snapshot.screen}: ${tile.snapshot.state} (${schemeNames[tile.scheme]})`}
      onClick={() => onSelect(tile)}
    >
      <img
        src={imageUrl(tile.variant)}
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
