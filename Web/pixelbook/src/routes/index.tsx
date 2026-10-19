import { createFileRoute, notFound, useNavigate } from "@tanstack/react-router";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Canvas, type CanvasHandle, type View } from "../Canvas.tsx";
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
  loadBook,
  NotPublished,
  type Platform,
  platforms,
  schemes,
  sourceOf,
  sourceUrl,
} from "../Snapshots.ts";
import { describeChanges, diffBooks, layoutDiff, summarize } from "../Diff.ts";
import { Labels, schemeNames, TileButton } from "../Tiles.tsx";

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
    <main className="message">
      <h1>Pixelbook</h1>
      {children}
    </main>
  );
}

const platformNames: Record<Platform, string> = { macos: "Mac", ios: "iPhone" };

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
  const [zoom, setZoom] = useState(0.1);
  const onViewChange = useCallback((view: View) => setZoom(view.zoom), []);

  return (
    <div className="app">
      <header className="toolbar">
        <h1>Pixelbook</h1>
        <a
          className="commit"
          href={`https://github.com/851-labs/lil.tech/commit/${book.commit}`}
          // GitHub opens in a new tab, keeping the canvas where it is.
          target="_blank"
          rel="noreferrer"
          title={`Snapshots from ${book.commit}`}
        >
          {search.commit === undefined ? `${search.ref ?? "main"} · ` : ""}
          {book.commit.slice(0, 7)}
        </a>
        {missingBase !== undefined && (
          <span className="comparing">
            no snapshots of {missingBase.slice(0, 7)} to compare with
            <button type="button" onClick={() => setSearch({ base: undefined })}>
              Show all
            </button>
          </span>
        )}
        {base !== undefined && (
          <span className="comparing">
            changes since{" "}
            <a
              href={`https://github.com/851-labs/lil.tech/compare/${base.commit}...${book.commit}`}
              target="_blank"
              rel="noreferrer"
            >
              {base.commit.slice(0, 7)}
            </a>
            <button type="button" onClick={() => setSearch({ base: undefined, tile: undefined })}>
              Show all
            </button>
          </span>
        )}
        {changes === undefined && (
          <div className="segmented" role="group" aria-label="Mode">
            {(["grid", "flow"] as const).map((value) => (
              <button
                key={value}
                type="button"
                className={mode === value ? "on" : ""}
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
        <Chips
          label="App"
          values={apps}
          chosen={filters.apps}
          name={(app) => appName(app, manifestPlatform(book, app))}
          onToggle={(app) => setSearch({ apps: toggle(apps, filters.apps, app) })}
        />
        <Chips
          label="Platform"
          values={platforms}
          chosen={filters.platforms}
          name={(platform) => platformNames[platform]}
          onToggle={(platform) =>
            setSearch({ platforms: toggle(platforms, filters.platforms, platform) })
          }
        />
        <Chips
          label="Appearance"
          values={schemes}
          chosen={filters.schemes}
          name={(scheme) => schemeNames[scheme]}
          onToggle={(scheme) => setSearch({ schemes: toggle(schemes, filters.schemes, scheme) })}
        />
        <div className="zoom" role="group" aria-label="Zoom">
          <button type="button" onClick={() => canvas.current?.zoomBy(1 / 1.5)} title="Zoom out">
            −
          </button>
          <span>{Math.round(zoom * 100)}%</span>
          <button type="button" onClick={() => canvas.current?.zoomBy(1.5)} title="Zoom in">
            +
          </button>
          <button type="button" onClick={() => canvas.current?.fit()} title="Show everything">
            Fit
          </button>
        </div>
        <span className="count">
          {changes !== undefined
            ? describeChanges(summarize(changes))
            : flow === undefined
              ? `${tiles.length} snapshots`
              : `${flow.nodes.length + flow.unlinked.length} screens`}
        </span>
      </header>
      <Canvas width={size.width} height={size.height} handle={canvas} onViewChange={onViewChange}>
        {grid !== undefined && (
          <Content tiles={grid.tiles} labels={grid.labels} onSelect={select} />
        )}
        {flow !== undefined && <FlowContent layout={flow} onSelect={select} />}
      </Canvas>
      {tiles.length === 0 && (
        <p className="empty">
          {changes?.length === 0 ? "No snapshots changed." : "No snapshots match these filters."}
        </p>
      )}
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
  );
}

const manifestPlatform = (book: Book, app: string): Platform =>
  book.manifests.find((manifest) => manifest.app === app)?.platform ?? "ios";

function Chips<A extends string>({
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
    <div className="chips" role="group" aria-label={label}>
      {values.map((value) => {
        const on = chosen.length === 0 || chosen.includes(value);
        return (
          <button
            key={value}
            type="button"
            className={on ? "chip on" : "chip"}
            aria-pressed={on}
            onClick={() => onToggle(value)}
          >
            {name(value)}
          </button>
        );
      })}
    </div>
  );
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
  return (
    <>
      <Labels labels={labels} />
      {tiles.map((tile) => (
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
    <aside className="detail" aria-label={`${snapshot.screen}: ${snapshot.state}`}>
      <header>
        <div>
          <h2>{snapshot.state}</h2>
          <p>
            {snapshot.screen} · {appName(tile.app, tile.platform)} · {schemeNames[tile.scheme]}
          </p>
        </div>
        <button type="button" className="close" onClick={onClose} title="Close (Esc)">
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
        <figure key={label ?? "image"} className="detail-figure">
          {label !== undefined && <figcaption>{label}</figcaption>}
          <div className={`detail-image ${tile.platform} ${tile.scheme}`}>
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
      <dl>
        <dt>Source</dt>
        <dd>
          <a href={sourceUrl(snapshot, commit)} target="_blank" rel="noreferrer">
            {snapshot.module}/{snapshot.file}
            {snapshot.line === null ? "" : `:${snapshot.line}`}
          </a>
        </dd>
        <dt>Size</dt>
        <dd>
          {tile.width} × {tile.height} pt @{variant.scale}x
        </dd>
      </dl>
    </aside>
  );
}
