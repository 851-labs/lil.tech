// The inspector, on the canvas's right (851-2764): the selected frame's image, details and
// changes, and what to do with it; with nothing selected, a summary of what the canvas shows.
import { useEffect, useState } from "react";
import { ExternalLink, plainButton, Segmented } from "./Controls.tsx";
import type { Tile } from "./Grid.ts";
import { appName, imageUrl, type Scheme, schemes, sourceUrl, type Variant } from "./Snapshots.ts";
import { platformNames, schemeNames, snapshotBackground } from "./Tiles.tsx";

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

const panel =
  "flex w-[400px] max-w-full shrink-0 flex-col gap-4 overflow-auto border-l border-border bg-surface p-4 max-lg:absolute max-lg:inset-y-0 max-lg:right-0 max-lg:z-3 max-lg:shadow-popover";

const sectionTitle = "text-mini font-medium text-secondary";

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
      <aside className={`${panel} max-xl:hidden`} aria-label="Summary">
        <SummaryView summary={summary} />
      </aside>
    );
  }
  return (
    <aside className={panel} aria-label={`${tile.snapshot.screen}: ${tile.snapshot.state}`}>
      <FrameView tile={tile} commit={commit} onClose={onClose} onZoomTo={onZoomTo} />
    </aside>
  );
}

function SummaryView({ summary }: { readonly summary: Summary }) {
  return (
    <>
      <header>
        <h2 className="text-regular font-semibold text-foreground">
          {summary.ref === undefined ? "Snapshots" : summary.ref}
        </h2>
        <p className="mt-0.5 text-secondary">
          {summary.shown} from{" "}
          <ExternalLink
            className="font-mono text-mini"
            href={`https://github.com/851-labs/lil.tech/commit/${summary.commit}`}
          >
            {summary.commit.slice(0, 7)}
          </ExternalLink>
        </p>
      </header>
      {summary.comparison !== undefined && (
        <section className="flex flex-col gap-1.5">
          <h3 className={sectionTitle}>
            Changes since{" "}
            <ExternalLink
              className="font-mono"
              href={`https://github.com/851-labs/lil.tech/compare/${summary.comparison.base}...${summary.commit}`}
            >
              {summary.comparison.base.slice(0, 7)}
            </ExternalLink>
          </h3>
          <dl className="grid grid-cols-[1fr_auto] gap-y-1">
            {summary.comparison.changes.map(([name, count]) => (
              <Row key={name} name={name} value={count} />
            ))}
          </dl>
        </section>
      )}
      <section className="flex flex-col gap-1.5">
        <h3 className={sectionTitle}>Apps</h3>
        <ul className="flex flex-col gap-1">
          {summary.apps.map((app) => (
            <li key={app}>{app}</li>
          ))}
        </ul>
      </section>
      <p className="text-secondary">
        Select a frame to inspect it. Press <kbd className="font-sans">?</kbd> for shortcuts.
      </p>
    </>
  );
}

/** A row of a two-column list, its value to the right. */
function Row({ name, value }: { readonly name: string; readonly value: React.ReactNode }) {
  return (
    <>
      <dt className="text-secondary">{name}</dt>
      <dd className="text-right tabular-nums [overflow-wrap:anywhere]">{value}</dd>
    </>
  );
}

function FrameView({
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
  // Which appearance the image shows: the frame's, until switched.
  const [scheme, setScheme] = useState<Scheme>(tile.scheme);
  useEffect(() => setScheme(tile.scheme), [tile]);
  // A comparison's frame is one appearance's change, so it shows only that one.
  const appearances = change === undefined ? schemes.filter((s) => snapshot.variants[s]) : [];
  const shown = (change === undefined ? snapshot.variants[scheme] : undefined) ?? variant;
  const shownScheme = shown === variant ? tile.scheme : scheme;
  const background = snapshotBackground(tile.platform, shownScheme);
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
        <button
          type="button"
          className="flex size-7 cursor-pointer items-center justify-center rounded-control text-large leading-none text-secondary hover:bg-hover hover:text-foreground"
          onClick={onClose}
          title="Close (Esc)"
        >
          ×
        </button>
      </header>

      <section className="flex flex-col gap-2">
        {change?.other !== undefined ? (
          <Compare
            before={change.label === "Before" ? variant : change.other}
            after={change.label === "Before" ? change.other : variant}
            background={background}
            alt={alt}
          />
        ) : (
          <>
            {appearances.length > 1 && (
              <Segmented
                label="Appearance"
                options={appearances.map((value) => ({ value, name: schemeNames[value] }))}
                value={shownScheme}
                onChange={setScheme}
              />
            )}
            {change !== undefined && <h3 className={sectionTitle}>{change.label}</h3>}
            <SnapshotImage variant={shown} background={background} alt={alt} />
          </>
        )}
      </section>

      <Actions image={shown} onZoomTo={onZoomTo} />

      <section className="flex flex-col gap-1.5">
        <h3 className={sectionTitle}>Details</h3>
        <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
          <Detail name="App">{appName(tile.app, tile.platform)}</Detail>
          <Detail name="Platform">{platformNames[tile.platform]}</Detail>
          <Detail name="Screen">{snapshot.screen}</Detail>
          <Detail name="State">{snapshot.state}</Detail>
          <Detail name="Appearance">{schemeNames[shownScheme]}</Detail>
          {change !== undefined && (
            <Detail name="Change">
              {change.other === undefined
                ? change.label
                : `Changed (${change.label.toLowerCase()})`}
            </Detail>
          )}
          <Detail name="Size">
            {shown.width / shown.scale} × {shown.height / shown.scale} pt @{shown.scale}x
          </Detail>
          <Detail name="Source">
            <ExternalLink href={sourceUrl(snapshot, commit)}>
              {snapshot.module}/{snapshot.file}
              {snapshot.line === null ? "" : `:${snapshot.line}`}
            </ExternalLink>
          </Detail>
        </dl>
      </section>
    </>
  );
}

function Detail({ name, children }: { readonly name: string; readonly children: React.ReactNode }) {
  return (
    <>
      <dt className="text-secondary">{name}</dt>
      <dd className="[overflow-wrap:anywhere]">{children}</dd>
    </>
  );
}

/** A snapshot at its size in points, or the panel's width if that's smaller. */
function SnapshotImage({
  variant,
  background,
  alt,
  className = "",
  style,
}: {
  readonly variant: Variant;
  readonly background: string;
  readonly alt: string;
  readonly className?: string;
  readonly style?: React.CSSProperties;
}) {
  return (
    <img
      className={`max-w-full rounded-control shadow-[0_0_0_1px_var(--color-border)] ${background} ${className}`}
      src={imageUrl(variant)}
      alt={alt}
      draggable={false}
      style={{
        width: variant.width / variant.scale,
        aspectRatio: `${variant.width} / ${variant.height}`,
        ...style,
      }}
    />
  );
}

type CompareMode = "sides" | "overlay" | "slider";

const compareModes: ReadonlyArray<{ readonly value: CompareMode; readonly name: string }> = [
  { value: "sides", name: "Side by side" },
  { value: "overlay", name: "Overlay" },
  { value: "slider", name: "Slider" },
];

/**
 * A changed snapshot's before and after: one above the other, the after over the before with an
 * opacity to fade between them, or split by a divider to drag across.
 */
function Compare({
  before,
  after,
  background,
  alt,
}: {
  readonly before: Variant;
  readonly after: Variant;
  readonly background: string;
  readonly alt: string;
}) {
  const [mode, setMode] = useState<CompareMode>("sides");
  // The after's opacity, or where the divider is, in percent.
  const [amount, setAmount] = useState(50);
  return (
    <>
      <Segmented label="Compare" options={compareModes} value={mode} onChange={setMode} />
      {mode === "sides" ? (
        <>
          <h3 className={sectionTitle}>Before</h3>
          <SnapshotImage variant={before} background={background} alt={`${alt}, before`} />
          <h3 className={sectionTitle}>After</h3>
          <SnapshotImage variant={after} background={background} alt={`${alt}, after`} />
        </>
      ) : (
        <>
          <label className="flex items-center gap-2 text-mini text-secondary">
            Before
            <input
              className="flex-1 accent-accent"
              type="range"
              min={0}
              max={100}
              value={amount}
              onChange={(event) => setAmount(Number(event.target.value))}
              aria-label={mode === "overlay" ? "After's opacity" : "Divider"}
            />
            After
          </label>
          <div className="relative self-start">
            <SnapshotImage variant={before} background={background} alt={`${alt}, before`} />
            <SnapshotImage
              variant={after}
              background={background}
              alt={`${alt}, after`}
              className="absolute top-0 left-0"
              style={
                mode === "overlay"
                  ? { opacity: amount / 100 }
                  : { clipPath: `inset(0 0 0 ${amount}%)` }
              }
            />
            {mode === "slider" && (
              <div
                className="pointer-events-none absolute inset-y-0 w-0.5 -translate-x-1/2 bg-accent"
                style={{ left: `${amount}%` }}
              />
            )}
          </div>
        </>
      )}
    </>
  );
}

/** Zoom to the frame, open its image full size, or copy a link to it. */
function Actions({ image, onZoomTo }: { readonly image: Variant; readonly onZoomTo: () => void }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timeout = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timeout);
  }, [copied]);
  return (
    <div className="flex flex-wrap gap-1.5">
      <button type="button" className={plainButton} onClick={onZoomTo} title="Zoom to it (⇧2)">
        Zoom to
      </button>
      <ExternalLink className={`${plainButton} hover:no-underline`} href={imageUrl(image)}>
        Open image
      </ExternalLink>
      <button
        type="button"
        className={plainButton}
        onClick={() =>
          void navigator.clipboard.writeText(window.location.href).then(() => setCopied(true))
        }
      >
        {copied ? "Copied" : "Copy link"}
      </button>
    </div>
  );
}
