import { createFileRoute, notFound, useNavigate } from "@tanstack/react-router";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Canvas, type CanvasHandle, useNear, type View } from "../Canvas.tsx";
import {
  filtersFrom,
  modeFrom,
  type SearchChange,
  toggle,
  validateSearch,
  withChange,
} from "../Filters.ts";
import { layoutFlowchart } from "../Flow.ts";
import { FlowContent } from "../FlowContent.tsx";
import { graphs } from "../graphs.ts";
import { type Label, layoutGrid, type Tile, tileId } from "../Grid.ts";
import {
  appName,
  type Book,
  imageUrl,
  tileDensity,
  loadBook,
  NotPublished,
  type Platform,
  platforms,
  schemes,
  sourceOf,
  sourceUrl,
} from "../Snapshots.ts";
import { describeChanges, diffBooks, layoutDiff, summarize } from "../Diff.ts";
import { DensityContext, Labels, schemeNames, snapshotBackground, TileButton } from "../Tiles.tsx";

export const Route = createFileRoute("/")({
  validateSearch,
  loaderDeps: ({ search }) => ({ ref: search.ref, commit: search.commit, base: search.base }),
  loader: async ({ deps }) => {
    try {
      const [book, base] = await Promise.all([
        loadBook(deps.commit === undefined ? { ref: deps.ref ?? "main" } : { commit: deps.commit }),
        // A base without snapshots doesn't hide the head's: the page says so instead.
        deps.base === undefined
          ? undefined
          : loadBook(sourceOf(deps.base)).catch((error: unknown) => {
              if (error instanceof NotPublished) return null;
              throw error;
            }),
      ]);
      return { book, base: base ?? undefined, missingBase: base === null ? deps.base : undefined };
    } catch (error) {
      // A 404, with the reason.
      if (error instanceof NotPublished) throw notFound({ data: error.message });
      throw error;
    }
  },
  component: Grid,
  notFoundComponent: ({ data }) => (
    <Message>
      <p>{typeof data === "string" ? data : "Nothing is published here."}</p>
      <p>
        Publish snapshots with <code>scripts/pixelbook publish</code>.
      </p>
    </Message>
  ),
  errorComponent: ({ error }) => (
    <Message>
      <p>Couldn't load snapshots: {error instanceof Error ? error.message : String(error)}</p>
    </Message>
  ),
});

function Message({ children }: { readonly children: React.ReactNode }) {
  return (
    <main className="mx-auto my-[120px] max-w-[560px] px-6 text-secondary [&_p]:my-[1em]">
      <h1 className="my-[0.67em] text-[2em] font-bold text-foreground">Pixelbook</h1>
      {children}
    </main>
  );
}

/** A link out of Pixelbook, such as to GitHub. It opens in a new tab, keeping the canvas where it is. */
function ExternalLink(props: Omit<React.ComponentProps<"a">, "target" | "rel">) {
  return <a {...props} target="_blank" rel="noreferrer" />;
}

const platformNames: Record<Platform, string> = { macos: "Mac", ios: "iPhone" };

/** A small control in the header, as Linear's: zoom, Show all and the like. */
const pillButton =
  "flex h-6 cursor-pointer items-center rounded-chip border px-2 text-mini font-medium";
/** One that isn't on: the zoom buttons, Show all, a chip that's off. */
const plainButton = `${pillButton} border-border text-muted hover:bg-hover`;

function Grid() {
  const { book, base, missingBase } = Route.useLoaderData();
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const apps = useMemo(() => book.manifests.map((manifest) => manifest.app).toSorted(), [book]);
  // Not the whole search: selecting a snapshot doesn't change the layout.
  const { apps: appsParameter, platforms: platformsParameter, schemes: schemesParameter } = search;
  const filters = useMemo(
    () =>
      filtersFrom(
        { apps: appsParameter, platforms: platformsParameter, schemes: schemesParameter },
        apps,
      ),
    [apps, appsParameter, platformsParameter, schemesParameter],
  );
  // Comparing with a base shows only what changed, laid out like the grid.
  const changes = useMemo(
    () => (base === undefined ? undefined : diffBooks(base, book)),
    [base, book],
  );
  const mode = changes === undefined ? modeFrom(search) : "grid";
  const grid = useMemo(
    () =>
      changes !== undefined
        ? layoutDiff(changes, filters)
        : mode === "grid"
          ? layoutGrid(book.manifests, filters)
          : undefined,
    [book, changes, filters, mode],
  );
  const flow = useMemo(
    () => (mode === "flow" ? layoutFlowchart(book.manifests, graphs, filters) : undefined),
    [book, filters, mode],
  );
  // Every tile there is to select.
  const tiles = useMemo(
    () =>
      grid?.tiles ?? [
        ...(flow?.nodes.flatMap((node) => node.tiles) ?? []),
        ...(flow?.unlinked ?? []),
      ],
    [grid, flow],
  );
  const size = grid ?? flow ?? { width: 0, height: 0 };
  const selected = tiles.find((tile) => tileId(tile) === search.tile);

  const setSearch = useCallback(
    (change: SearchChange) =>
      void navigate({ search: (previous) => withChange(previous, change), replace: true }),
    [navigate],
  );
  const select = useCallback(
    (tile: Tile | undefined) => setSearch({ tile: tile === undefined ? undefined : tileId(tile) }),
    [setSearch],
  );
  const open = selected !== undefined;
  useEffect(() => {
    if (!open) return;
    const close = (event: KeyboardEvent) => event.key === "Escape" && select(undefined);
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [open, select]);

  const canvas = useRef<CanvasHandle>(null);
  // Unknown until the canvas has measured itself.
  const [zoom, setZoom] = useState<number>();
  const onViewChange = useCallback((view: View) => setZoom(view.zoom), []);
  const devicePixelRatio = useDevicePixelRatio();
  const density = zoom === undefined ? undefined : tileDensity(zoom, devicePixelRatio);

  const sidebar = useSidebar();

  return (
    <div className="fixed inset-0 flex flex-col">
      <header className="flex h-11 shrink-0 items-center gap-2 border-b border-border bg-surface px-3">
        <button
          type="button"
          className={`${plainButton} border-transparent px-1.5`}
          onClick={sidebar.toggle}
          aria-pressed={sidebar.open}
          title={sidebar.open ? "Hide the sidebar" : "Show the sidebar"}
        >
          <SidebarIcon />
        </button>
        <h1 className="mr-1 text-small font-semibold text-foreground">Pixelbook</h1>
        <ExternalLink
          className="font-mono text-mini text-secondary"
          href={`https://github.com/851-labs/lil.tech/commit/${book.commit}`}
          title={`Snapshots from ${book.commit}`}
        >
          {search.commit === undefined ? `${search.ref ?? "main"} · ` : ""}
          {book.commit.slice(0, 7)}
        </ExternalLink>
        {missingBase !== undefined && (
          <span className="flex min-w-0 items-center gap-1.5 truncate text-mini text-secondary">
            no snapshots of {missingBase.slice(0, 7)} to compare with
            <button
              type="button"
              className={plainButton}
              onClick={() => setSearch({ base: undefined })}
            >
              Show all
            </button>
          </span>
        )}
        {base !== undefined && (
          <span className="flex min-w-0 items-center gap-1.5 text-mini text-secondary">
            changes since{" "}
            <ExternalLink
              className="font-mono text-mini"
              href={`https://github.com/851-labs/lil.tech/compare/${base.commit}...${book.commit}`}
            >
              {base.commit.slice(0, 7)}
            </ExternalLink>
            <button
              type="button"
              className={plainButton}
              onClick={() => setSearch({ base: undefined, tile: undefined })}
            >
              Show all
            </button>
          </span>
        )}
        {changes === undefined && (
          <div
            className="flex rounded-control border border-border p-0.5"
            role="group"
            aria-label="Mode"
          >
            {(["grid", "flow"] as const).map((value) => (
              <button
                key={value}
                type="button"
                className={`h-6 cursor-pointer rounded-chip px-2.5 text-mini font-medium ${mode === value ? "bg-selected text-foreground" : "text-secondary hover:bg-hover hover:text-muted"}`}
                aria-pressed={mode === value}
                // A tile from one mode may not be in the other.
                onClick={() =>
                  setSearch({ mode: value === "grid" ? undefined : value, tile: undefined })
                }
              >
                {value === "grid" ? "Grid" : "Flow"}
              </button>
            ))}
          </div>
        )}
        <span className="ml-auto truncate text-mini text-secondary max-sm:hidden">
          {changes !== undefined
            ? describeChanges(summarize(changes))
            : flow === undefined
              ? `${tiles.length} snapshots`
              : `${flow.nodes.length + flow.unlinked.length} screens`}
        </span>
        <div className="flex items-center gap-1 max-sm:ml-auto" role="group" aria-label="Zoom">
          <button
            type="button"
            className={plainButton}
            onClick={() => canvas.current?.zoomBy(1 / 1.5)}
            title="Zoom out"
          >
            −
          </button>
          <span className="min-w-10 text-center text-mini text-secondary tabular-nums">
            {zoom === undefined ? "" : `${Math.round(zoom * 100)}%`}
          </span>
          <button
            type="button"
            className={plainButton}
            onClick={() => canvas.current?.zoomBy(1.5)}
            title="Zoom in"
          >
            +
          </button>
          <button
            type="button"
            className={plainButton}
            onClick={() => canvas.current?.fit()}
            title="Show everything"
          >
            Fit
          </button>
        </div>
      </header>
      <div className="relative flex min-h-0 flex-1">
        {sidebar.open && (
          <Sidebar width={sidebar.width} onResize={sidebar.resize}>
            <FilterList
              label="Apps"
              values={apps}
              chosen={filters.apps}
              name={(app) => appName(app, manifestPlatform(book, app))}
              onToggle={(app) => setSearch({ apps: toggle(apps, filters.apps, app) })}
            />
            <FilterList
              label="Platforms"
              values={platforms}
              chosen={filters.platforms}
              name={(platform) => platformNames[platform]}
              onToggle={(platform) =>
                setSearch({ platforms: toggle(platforms, filters.platforms, platform) })
              }
            />
            <FilterList
              label="Appearances"
              values={schemes}
              chosen={filters.schemes}
              name={(scheme) => schemeNames[scheme]}
              onToggle={(scheme) =>
                setSearch({ schemes: toggle(schemes, filters.schemes, scheme) })
              }
            />
          </Sidebar>
        )}
        <main className="relative min-w-0 flex-1 bg-background">
          <Canvas
            width={size.width}
            height={size.height}
            handle={canvas}
            onViewChange={onViewChange}
          >
            <DensityContext value={density}>
              {grid !== undefined && (
                <Content tiles={grid.tiles} labels={grid.labels} onSelect={select} />
              )}
              {flow !== undefined && <FlowContent layout={flow} onSelect={select} />}
            </DensityContext>
          </Canvas>
          {tiles.length === 0 && (
            <p className="pointer-events-none absolute top-1/2 right-0 left-0 text-center text-secondary">
              {changes?.length === 0
                ? "No snapshots changed."
                : "No snapshots match these filters."}
            </p>
          )}
        </main>
        {selected !== undefined && (
          <Detail
            tile={selected}
            // A base-side tile's file and line are the base's.
            commit={
              base !== undefined &&
              (selected.change?.label === "Before" || selected.change?.label === "Removed")
                ? base.commit
                : book.commit
            }
            onClose={() => select(undefined)}
          />
        )}
      </div>
    </div>
  );
}

/** The sidebar's width, in CSS pixels: as Linear's, and how far it can be dragged. */
const sidebarWidth = { initial: 244, min: 200, max: 400 };
/** Narrower than this, the sidebar starts hidden, so the canvas has the room. */
const narrowQuery = "(max-width: 899px)";

/**
 * Whether the sidebar shows, and how wide it is. Hidden while the window is narrow, and shown again
 * when it widens, unless toggled since. The width is remembered across visits.
 */
function useSidebar() {
  const [open, setOpen] = useState(true);
  const [width, setWidth] = useState(sidebarWidth.initial);
  useEffect(() => {
    const stored = Number(localStorage.getItem("pixelbook.sidebarWidth"));
    if (stored >= sidebarWidth.min && stored <= sidebarWidth.max) setWidth(stored);
    const narrow = window.matchMedia(narrowQuery);
    setOpen(!narrow.matches);
    const follow = (event: MediaQueryListEvent) => setOpen(!event.matches);
    narrow.addEventListener("change", follow);
    return () => narrow.removeEventListener("change", follow);
  }, []);
  const resize = useCallback((to: number) => {
    const clamped = Math.round(Math.min(sidebarWidth.max, Math.max(sidebarWidth.min, to)));
    setWidth(clamped);
    localStorage.setItem("pixelbook.sidebarWidth", String(clamped));
  }, []);
  const toggle = useCallback(() => setOpen((open) => !open), []);
  return { open, width, resize, toggle };
}

/** The left sidebar: what to show on the canvas. Its right edge drags to resize it. */
function Sidebar({
  width,
  onResize,
  children,
}: {
  readonly width: number;
  readonly onResize: (width: number) => void;
  readonly children: React.ReactNode;
}) {
  const start = useRef<{ x: number; width: number } | null>(null);
  return (
    <aside
      className="relative flex shrink-0 flex-col gap-4 overflow-auto border-r border-border bg-surface px-2 py-3 max-[899px]:absolute max-[899px]:inset-y-0 max-[899px]:left-0 max-[899px]:z-3 max-[899px]:shadow-popover"
      style={{ width }}
      aria-label="Filters"
    >
      {children}
      <div
        className="absolute inset-y-0 -right-1 w-2 cursor-col-resize hover:bg-accent/20"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the sidebar"
        onPointerDown={(event) => {
          event.currentTarget.setPointerCapture(event.pointerId);
          start.current = { x: event.clientX, width };
        }}
        onPointerMove={(event) => {
          if (start.current === null) return;
          onResize(start.current.width + event.clientX - start.current.x);
        }}
        onPointerUp={() => (start.current = null)}
        onPointerCancel={() => (start.current = null)}
      />
    </aside>
  );
}

function SidebarIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" />
      <path d="M6 2.5v11" stroke="currentColor" />
    </svg>
  );
}

const manifestPlatform = (book: Book, app: string): Platform =>
  book.manifests.find((manifest) => manifest.app === app)?.platform ?? "ios";

/** A filter's choices, as a list in the sidebar: each one on unless chosen otherwise. */
function FilterList<A extends string>({
  label,
  values,
  chosen,
  name,
  onToggle,
}: {
  readonly label: string;
  readonly values: ReadonlyArray<A>;
  readonly chosen: ReadonlyArray<A>;
  readonly name: (value: A) => string;
  readonly onToggle: (value: A) => void;
}) {
  return (
    <section className="flex flex-col gap-0.5" aria-label={label}>
      <h2 className="px-2 pb-1 text-mini font-medium text-secondary">{label}</h2>
      {values.map((value) => {
        const on = chosen.length === 0 || chosen.includes(value);
        return (
          <button
            key={value}
            type="button"
            className={`flex h-7 cursor-pointer items-center gap-2 rounded-chip px-2 text-left text-small hover:bg-hover ${on ? "text-foreground" : "text-secondary"}`}
            aria-pressed={on}
            onClick={() => onToggle(value)}
          >
            <span
              className={`flex size-3.5 shrink-0 items-center justify-center rounded-[4px] border ${on ? "border-accent bg-accent text-white" : "border-border"}`}
              aria-hidden="true"
            >
              {on && (
                <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
                  <path d="M2 5.2 4.1 7.3 8 2.8" stroke="currentColor" strokeWidth="1.6" />
                </svg>
              )}
            </span>
            <span className="truncate">{name(value)}</span>
          </button>
        );
      })}
    </section>
  );
}

/** The display's pixels per CSS pixel, kept up to date as the window moves between displays. */
function useDevicePixelRatio() {
  const [ratio, setRatio] = useState(1);
  useEffect(() => {
    let query: MediaQueryList | undefined;
    const watch = () => {
      setRatio(window.devicePixelRatio);
      // Matches until the ratio changes, then is replaced.
      query = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
      query.addEventListener("change", watch, { once: true });
    };
    watch();
    return () => query?.removeEventListener("change", watch);
  }, []);
  return ratio;
}

/** The grid's tiles and labels. Memoized: panning and zooming don't change them. */
const Content = memo(function Content({
  tiles,
  labels,
  onSelect,
}: {
  readonly tiles: ReadonlyArray<Tile>;
  readonly labels: ReadonlyArray<Label>;
  readonly onSelect: (tile: Tile) => void;
}) {
  // Only what's near the view: re-rendered as that changes, not on every pan.
  const shown = useNear(tiles, (tile) => tile);
  return (
    <>
      <Labels labels={labels} />
      {shown.map((tile) => (
        <TileButton key={tileId(tile)} tile={tile} onSelect={onSelect} />
      ))}
    </>
  );
});

function Detail({
  tile,
  commit,
  onClose,
}: {
  readonly tile: Tile;
  readonly commit: string;
  readonly onClose: () => void;
}) {
  const { snapshot, variant } = tile;
  return (
    <aside
      className="flex w-[400px] max-w-full shrink-0 flex-col gap-3 overflow-auto border-l border-border bg-surface p-4 max-lg:absolute max-lg:inset-y-0 max-lg:right-0 max-lg:z-3 max-lg:shadow-popover"
      aria-label={`${snapshot.screen}: ${snapshot.state}`}
    >
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-regular font-semibold text-foreground">{snapshot.state}</h2>
          <p className="mt-0.5 text-secondary">
            {snapshot.screen} · {appName(tile.app, tile.platform)} · {schemeNames[tile.scheme]}
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
      {/* A changed snapshot shows both sides, before first. */}
      {(tile.change?.other === undefined
        ? [{ label: tile.change?.label, image: variant }]
        : tile.change.label === "Before"
          ? [
              { label: "Before", image: variant },
              { label: "After", image: tile.change.other },
            ]
          : [
              { label: "Before", image: tile.change.other },
              { label: "After", image: variant },
            ]
      ).map(({ label, image }) => (
        <figure key={label ?? "image"} className="flex flex-col gap-1.5">
          {label !== undefined && (
            <figcaption className="text-mini font-medium text-secondary">{label}</figcaption>
          )}
          <div
            className={`max-w-full self-center overflow-hidden rounded-control shadow-[0_0_0_1px_var(--color-border)] ${snapshotBackground(tile.platform, tile.scheme)}`}
          >
            <img
              src={imageUrl(image)}
              alt={`${snapshot.screen}: ${snapshot.state}${label === undefined ? "" : `, ${label}`}`}
              style={{
                width: image.width / image.scale,
                aspectRatio: `${image.width} / ${image.height}`,
              }}
            />
          </div>
        </figure>
      ))}
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt className="text-secondary">Source</dt>
        <dd className="[overflow-wrap:anywhere]">
          <ExternalLink href={sourceUrl(snapshot, commit)}>
            {snapshot.module}/{snapshot.file}
            {snapshot.line === null ? "" : `:${snapshot.line}`}
          </ExternalLink>
        </dd>
        <dt className="text-secondary">Size</dt>
        <dd className="[overflow-wrap:anywhere]">
          {tile.width} × {tile.height} pt @{variant.scale}x
        </dd>
      </dl>
    </aside>
  );
}
