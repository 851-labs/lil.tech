// The inspector, on the canvas's right (851-2764): the selected frame's details, a change's before
// and after, and what to do with it; with nothing selected, a summary of what the canvas shows.
import { Panel } from "../comps/Panel.tsx";
import { type Tile, tileId } from "../lib/Grid.ts";
import { FrameView } from "./FrameView.tsx";
import { SummaryView } from "./SummaryView.tsx";

/** What the canvas shows, for the inspector to sum up when nothing is selected. */
export interface Summary {
  readonly commit: string;
  /** The branch it was published to, when shown by branch rather than by commit. */
  readonly ref: string | undefined;
  /** What's on the canvas, e.g. "450 snapshots". */
  readonly shown: string;
  readonly apps: ReadonlyArray<string>;
  /** In a comparison: its base's commit, and what changed. */
  readonly comparison:
    | { readonly base: string; readonly changes: ReadonlyArray<readonly [string, number]> }
    | undefined;
}

export function Inspector({
  tile,
  commit,
  summary,
  onClose,
  onZoomTo,
}: {
  /** The selected frame's, if any. */
  readonly tile: Tile | undefined;
  /** The commit its source is at: the base's, for a comparison's before side. */
  readonly commit: string;
  readonly summary: Summary;
  readonly onClose: () => void;
  readonly onZoomTo: () => void;
}) {
  if (tile === undefined) {
    return (
      // Without a selection it only shows in wide windows, beside the canvas rather than over it.
      <Panel label="Summary" className="max-xl:hidden">
        <SummaryView summary={summary} />
      </Panel>
    );
  }
  return (
    <Panel label={`${tile.snapshot.screen}: ${tile.snapshot.state}`}>
      {/* Keyed, so its state, such as the comparison mode, starts over with each frame. */}
      <FrameView
        key={tileId(tile)}
        tile={tile}
        commit={commit}
        onClose={onClose}
        onZoomTo={onZoomTo}
      />
    </Panel>
  );
}
