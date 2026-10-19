import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Canvas, type CanvasHandle, type View } from "../Canvas.tsx";
import { filtersFrom, type Search, toggle, validateSearch } from "../Filters.ts";
import { type Label, layoutGrid, type Tile, tileId } from "../Grid.ts";
import {
  appName,
  type Book,
  imageUrl,
  loadBook,
  NotPublished,
  type Platform,
  platforms,
  type Scheme,
  schemes,
  sourceUrl,
} from "../Snapshots.ts";

export const Route = createFileRoute("/")({
  validateSearch,
  loaderDeps: ({ search }) => ({ ref: search.ref, commit: search.commit }),
  loader: ({ deps }) =>
    loadBook(deps.commit === undefined ? { ref: deps.ref ?? "main" } : { commit: deps.commit }),
  component: Grid,
  errorComponent: ({ error }) => (
    <main className="message">
      <h1>Pixelbook</h1>
      <p>
        {error instanceof NotPublished
          ? error.message
          : `Couldn't load snapshots: ${error instanceof Error ? error.message : String(error)}`}
      </p>
      {error instanceof NotPublished && (
        <p>
          Publish snapshots with <code>scripts/pixelbook publish</code>.
        </p>
      )}
    </main>
  ),
});

const platformNames: Record<Platform, string> = { macos: "Mac", ios: "iPhone" };
const schemeNames: Record<Scheme, string> = { light: "Light", dark: "Dark" };

function Grid() {
  const book = Route.useLoaderData();
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const filters = filtersFrom(search);
  const layout = useMemo(() => layoutGrid(book.manifests, filters), [book, search]);
  const selected = layout.tiles.find((tile) => tileId(tile) === search.tile);

  const setSearch = useCallback(
    (change: { [Name in keyof Search]?: Search[Name] | undefined }) =>
      void navigate({ search: (previous) => withChange(previous, change), replace: true }),
    [navigate],
  );
  const select = useCallback(
    (tile: Tile | undefined) => setSearch({ tile: tile === undefined ? undefined : tileId(tile) }),
    [setSearch],
  );
  useEffect(() => {
    const close = (event: KeyboardEvent) => event.key === "Escape" && select(undefined);
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [select]);

  const canvas = useRef<CanvasHandle>(null);
  const [zoom, setZoom] = useState(0.1);
  const onViewChange = useCallback((view: View) => setZoom(view.zoom), []);
  const apps = book.manifests.map((manifest) => manifest.app).toSorted();

  return (
    <div className="app">
      <header className="toolbar">
        <h1>Pixelbook</h1>
        <a
          className="commit"
          href={`https://github.com/851-labs/lil.tech/commit/${book.commit}`}
          title={`Snapshots from ${book.commit}`}
        >
          {search.commit === undefined ? `${search.ref ?? "main"} · ` : ""}
          {book.commit.slice(0, 7)}
        </a>
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
        <span className="count">{layout.tiles.length} snapshots</span>
      </header>
      <Canvas
        width={layout.width}
        height={layout.height}
        handle={canvas}
        onViewChange={onViewChange}
      >
        <Content tiles={layout.tiles} labels={layout.labels} onSelect={select} />
      </Canvas>
      {selected !== undefined && (
        <Detail tile={selected} commit={book.commit} onClose={() => select(undefined)} />
      )}
    </div>
  );
}

/** `search` with `change`'s parameters, leaving out those it clears. */
const withChange = (
  search: Search,
  change: { [Name in keyof Search]?: Search[Name] | undefined },
): Search =>
  Object.fromEntries(
    Object.entries({ ...search, ...change }).filter(([, value]) => value !== undefined),
  );

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

/** The canvas's tiles and labels. Memoized: panning and zooming don't change them. */
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
      {labels.map((label) => (
        <div
          key={`${label.kind}/${label.y}`}
          className={`label ${label.kind}`}
          style={{ left: label.x, top: label.y }}
        >
          {label.text}
        </div>
      ))}
      {tiles.map((tile) => (
        <button
          key={tileId(tile)}
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
      <div className={`detail-image ${tile.platform} ${tile.scheme}`}>
        <img
          src={imageUrl(variant)}
          alt={`${snapshot.screen}: ${snapshot.state}`}
          style={{ width: tile.width, aspectRatio: `${tile.width} / ${tile.height}` }}
        />
      </div>
      <dl>
        <dt>Source</dt>
        <dd>
          <a href={sourceUrl(snapshot, commit)}>
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
