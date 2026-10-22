import { snapshotBackground } from "../comps/SnapshotStyles.ts";
import { Button } from "../comps/Button.tsx";
import { Detail, DetailList } from "../comps/Detail.tsx";
import { ExternalLink } from "../comps/ExternalLink.tsx";
import { SectionTitle } from "../comps/SectionTitle.tsx";
import { Tooltip } from "../comps/Tooltip.tsx";
import type { Tile } from "../lib/Grid.ts";
import {
  appName,
  imageUrl,
  platformNames,
  schemeNames,
  schemes,
  sourceLabel,
  sourceUrl,
} from "../lib/Snapshots.ts";
import { Actions } from "./Actions.tsx";
import { Compare } from "./Compare.tsx";

/** The selected frame: its state and screen, a change's before and after, actions and details. */
export function FrameView({
  tile,
  commit,
  onClose,
  onZoomTo,
}: {
  readonly tile: Tile;
  readonly commit: string;
  readonly onClose: () => void;
  readonly onZoomTo: () => void;
}) {
  const { snapshot, variant, change } = tile;
  // The snapshot's other appearance, if it has one; a comparison's frame is one appearance's change.
  const otherScheme = schemes.find((scheme) => scheme !== tile.scheme);
  const otherVariant = otherScheme === undefined ? undefined : snapshot.variants[otherScheme];
  const other =
    change === undefined && otherScheme !== undefined && otherVariant !== undefined
      ? { scheme: otherScheme, variant: otherVariant }
      : undefined;
  const background = snapshotBackground(tile.platform, tile.scheme);
  const alt = `${snapshot.screen}: ${snapshot.state}`;
  return (
    <>
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-regular font-semibold text-foreground">{snapshot.state}</h2>
          <p className="mt-0.5 text-secondary">
            {snapshot.screen} · {appName(tile.app, tile.platform)}
          </p>
        </div>
        <Tooltip label="Close" keys="Esc">
          <Button variant="icon" onClick={onClose} aria-label="Close" aria-keyshortcuts="Escape">
            ×
          </Button>
        </Tooltip>
      </header>

      {/* The canvas shows the frame itself (851-2788); only a change's before and after are shown
          here, since nowhere else compares them. */}
      {change?.other !== undefined && (
        <section className="flex flex-col gap-2">
          <Compare
            before={change.label === "Before" ? variant : change.other}
            after={change.label === "Before" ? change.other : variant}
            background={background}
            alt={alt}
          />
        </section>
      )}

      <Actions image={variant} onZoomTo={onZoomTo} />

      <section className="flex flex-col gap-1.5">
        <SectionTitle>Details</SectionTitle>
        <DetailList>
          <Detail name="App">{appName(tile.app, tile.platform)}</Detail>
          <Detail name="Platform">{platformNames[tile.platform]}</Detail>
          <Detail name="Screen">{snapshot.screen}</Detail>
          <Detail name="State">{snapshot.state}</Detail>
          <Detail name="Appearance">
            {schemeNames[tile.scheme]}
            {/* The flowchart shows one appearance per state, so the other is a link here. */}
            {other !== undefined && (
              <>
                {" · "}
                <ExternalLink href={imageUrl(other.variant)}>
                  Open {schemeNames[other.scheme]}
                </ExternalLink>
              </>
            )}
          </Detail>
          {change !== undefined && (
            <Detail name="Change">
              {change.other === undefined
                ? change.label
                : `Changed (${change.label.toLowerCase()})`}
            </Detail>
          )}
          <Detail name="Size">
            {variant.width / variant.scale} × {variant.height / variant.scale} pt @{variant.scale}x
          </Detail>
          <Detail name="Source">
            <ExternalLink href={sourceUrl(snapshot, commit)}>
              {sourceLabel(snapshot)}
              {snapshot.line === null ? "" : `:${snapshot.line}`}
            </ExternalLink>
          </Detail>
        </DetailList>
      </section>
    </>
  );
}
