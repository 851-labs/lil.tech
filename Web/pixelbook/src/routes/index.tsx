import { createFileRoute, notFound, useNavigate } from "@tanstack/react-router";
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Canvas, type CanvasHandle, type Insets } from "../Canvas.tsx";
import { ExternalLink, plainButton, Segmented } from "../Controls.tsx";
import { flowNodes, gridNodes, withSteps } from "../Elements.ts";
import { type Direction, flowFrames, frameOf, gridFrames, neighbor } from "../Selection.ts";
import {
  filtersFrom,
  modeFrom,
  type SearchChange,
  toggle,
  validateSearch,
  withChange,
} from "../Filters.ts";
import { layoutFlowchart } from "../Flow.ts";
import { Inspector, type Summary } from "../Inspector.tsx";
import { flowLayers, gridLayers, type LayerState } from "../Layers.ts";
import { LayersList } from "../LayersList.tsx";
import { RoutesNodeView, ScreenNodeView, StepContext, useSteps } from "../FlowNodes.tsx";
import { graphs } from "../graphs.ts";
import { layoutGrid, type Tile, tileId } from "../Grid.ts";
import {
  appName,
  type Book,
  commitUrl,
  compareUrl,
  tileDensity,
  loadBook,
  NotPublished,
  type Platform,
  platforms,
  schemes,
  sourceOf,
} from "../Snapshots.ts";
import { describeChanges, diffBooks, layoutDiff, shownChanges, summarize } from "../Diff.ts";
import {
  DensityContext,
  LabelNodeView,
  platformNames,
  schemeNames,
  SelectContext,
  SelectedContext,
  TileNodeView,
} from "../Tiles.tsx";

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

const nodeTypes = {
  tile: TileNodeView,
  label: LabelNodeView,
  screen: ScreenNodeView,
  routes: RoutesNodeView,
};

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
  const [steps, step] = useSteps();
  const laidOut = useMemo(
    () => (grid !== undefined ? gridNodes(grid) : flow !== undefined ? flowNodes(flow) : []),
    [grid, flow],
  );
  const nodes = useMemo(() => withSteps(laidOut, steps), [laidOut, steps]);
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
  const deselect = useCallback(() => select(undefined), [select]);
  // A click on the empty canvas, which deselects.
  const selectedId = search.tile;
  const onPaneClick = useCallback(() => {
    if (selectedId !== undefined) deselect();
  }, [selectedId, deselect]);

  const canvas = useRef<CanvasHandle>(null);
  // What the arrow keys move between, and where the selection is.
  const frames = useMemo(
    () =>
      grid !== undefined
        ? gridFrames(grid.tiles)
        : flow !== undefined
          ? flowFrames(flow, steps)
          : [],
    [grid, flow, steps],
  );
  const selectedFrame = frameOf(frames, search.tile);

  // The panels beside the canvas, which narrow windows show over it.
  const body = useRef<HTMLDivElement>(null);
  const covered = useCallback((): Insets => {
    let insets = { left: 0, right: 0 };
    for (const panel of body.current?.querySelectorAll<HTMLElement>(":scope > aside") ?? []) {
      if (getComputedStyle(panel).position !== "absolute") continue;
      insets =
        panel.offsetLeft === 0
          ? { ...insets, left: panel.offsetWidth }
          : { ...insets, right: panel.offsetWidth };
    }
    return insets;
  }, []);
  // A frame to show once the selection, and the inspector it opens, are laid out: panned to when
  // the arrow keys select it, or zoomed to when the layers list does. `shows` counts requests, so
  // choosing the selected frame again zooms to it too.
  const toShow = useRef<
    | {
        readonly id: string;
        readonly zoom: boolean;
        /** What was selected when it was asked for, until the selection catches up. */
        readonly from: string | undefined;
      }
    | undefined
  >(undefined);
  const [shows, setShows] = useState(0);
  const show = useCallback(
    (tile: Tile, zoom: boolean) => {
      toShow.current = { id: tileId(tile), zoom, from: selectedId };
      select(tile);
      setShows((count) => count + 1);
    },
    [select, selectedId],
  );
  useEffect(() => {
    const target = toShow.current;
    if (target === undefined) return;
    if (selectedId !== target.id) {
      // Not selected yet; or selected, then something else was, so it's dropped.
      if (selectedId !== target.from) toShow.current = undefined;
      return;
    }
    toShow.current = undefined;
    // A stepped flowchart screen's frame shows the state it was stepped to.
    const frame = frameOf(frames, target.id);
    if (frame === undefined) return;
    const next = requestAnimationFrame(() =>
      target.zoom
        ? canvas.current?.zoomTo(frame.box, covered())
        : canvas.current?.reveal(frame.box, covered()),
    );
    return () => cancelAnimationFrame(next);
  }, [shows, selectedId, frames, covered]);

  const zoomToSelection = useCallback(() => {
    if (selectedFrame !== undefined) canvas.current?.zoomTo(selectedFrame.box, covered());
  }, [selectedFrame, covered]);

  // What the canvas shows, for the header and the inspector.
  const counts = useMemo(
    () => (changes === undefined ? undefined : summarize(shownChanges(changes, filters))),
    [changes, filters],
  );
  const shown =
    counts !== undefined
      ? describeChanges(counts)
      : flow === undefined
        ? `${tiles.length} snapshots`
        : `${flow.nodes.length + flow.unlinked.length} screens`;
  const summary = useMemo(
    (): Summary => ({
      commit: book.commit,
      ref: search.commit === undefined ? (search.ref ?? "main") : undefined,
      shown,
      // Those on the canvas, in its order.
      apps: [...new Set(tiles.map((tile) => appName(tile.app, tile.platform)))],
      comparison:
        base === undefined || counts === undefined
          ? undefined
          : {
              base: base.commit,
              changes: [
                ["Changed", counts.changed],
                ["New", counts.added],
                ["Removed", counts.removed],
                ["Screens", counts.screens],
              ],
            },
    }),
    [book, base, counts, search.commit, search.ref, shown, tiles],
  );

  // The sidebar's list of what's on the canvas. Choosing a state steps its flowchart screen to it,
  // selects it and zooms to it.
  const layers = useMemo(
    () =>
      grid !== undefined ? gridLayers(grid.tiles) : flow !== undefined ? flowLayers(flow) : [],
    [grid, flow],
  );
  const choose = useCallback(
    (state: LayerState) => {
      if (state.step !== undefined) step(state.step.key, state.step.index);
      show(state.tile, true);
    },
    [step, show],
  );

  const [helpShown, setHelpShown] = useState(false);
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isTyping(event.target)) return;
      const view = canvas.current;
      const direction = arrowDirections[event.key];
      // Shortcuts with other modifiers are the browser's or the system's.
      const plain = !event.metaKey && !event.ctrlKey && !event.altKey;
      if (event.key === "Escape") {
        if (helpShown) setHelpShown(false);
        else if (search.tile !== undefined) deselect();
        else return;
      } else if (event.key === "?" && plain) {
        if (!event.repeat) setHelpShown((shown) => !shown);
      } else if (helpShown) {
        // The rest wait until the list is closed.
        return;
      } else if (direction !== undefined && plain && !event.shiftKey) {
        // In the sidebar or inspector, they scroll it.
        if (inPanel(event.target)) return;
        // With nothing selected, the first frame.
        const next =
          selectedFrame === undefined ? frames[0] : neighbor(frames, selectedFrame, direction);
        if (next === undefined) return;
        // So Space or Enter doesn't press a tile clicked before.
        const focused = document.activeElement;
        if (focused instanceof HTMLElement && focused.closest(".react-flow") !== null)
          focused.blur();
        show(next.tile, false);
      } else if (plain && event.shiftKey && event.code === "Digit1") {
        view?.fit();
      } else if (plain && event.shiftKey && event.code === "Digit2") {
        zoomToSelection();
      } else if ((event.key === "+" || event.key === "=") && !event.altKey) {
        // With ⌘ too, rather than the browser zooming the page.
        view?.zoomBy(1.5);
      } else if ((event.key === "-" || event.key === "_") && !event.altKey) {
        view?.zoomBy(1 / 1.5);
      } else {
        return;
      }
      event.preventDefault();
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, [frames, selectedFrame, search.tile, show, deselect, helpShown, zoomToSelection]);

  // Stepping the selected flowchart screen selects the state it steps to, which it shows.
  const stepScreen = useCallback(
    (key: string, to: number) => {
      step(key, to);
      const node = flow?.nodes.find((node) => node.key === key);
      const tile = node?.tiles[to % node.tiles.length];
      if (tile !== undefined && node?.tiles.some((state) => tileId(state) === search.tile))
        select(tile);
    },
    [step, flow, search.tile, select],
  );
  // Unknown until the canvas has measured itself.
  const [zoom, setZoom] = useState<number>();

  const devicePixelRatio = useDevicePixelRatio();
  const density = zoom === undefined ? undefined : tileDensity(zoom, devicePixelRatio);

  const sidebar = useSidebar();

  return (
    <div className="fixed inset-0 flex flex-col">
      <header className="flex min-h-11 shrink-0 flex-wrap items-center gap-x-2 gap-y-1 border-b border-border bg-surface px-3 py-1.5">
        <button
          type="button"
          className={`${plainButton} border-transparent px-1.5`}
          onClick={sidebar.toggle}
          title="Show or hide the sidebar"
        >
          <SidebarIcon />
        </button>
        <h1 className="mr-1 text-small font-semibold text-foreground">Pixelbook</h1>
        <ExternalLink
          className="font-mono text-mini text-secondary"
          href={commitUrl(book.commit)}
          title={`Snapshots from ${book.commit}`}
        >
          {search.commit === undefined ? `${search.ref ?? "main"} · ` : ""}
          {book.commit.slice(0, 7)}
        </ExternalLink>
        {missingBase !== undefined && (
          <span className="flex flex-wrap items-center gap-1.5 text-mini text-secondary">
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
          <span className="flex flex-wrap items-center gap-1.5 text-mini text-secondary">
            changes since{" "}
            <ExternalLink
              className="font-mono text-mini"
              href={compareUrl(base.commit, book.commit)}
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
          <Segmented
            label="Mode"
            options={modes}
            value={mode}
            // A tile from one mode may not be in the other.
            onChange={(value) =>
              setSearch({ mode: value === "grid" ? undefined : value, tile: undefined })
            }
          />
        )}
        <span className="ml-auto truncate text-mini text-secondary max-sm:hidden">{shown}</span>
        <div className="flex items-center gap-1 max-sm:ml-auto" role="group" aria-label="Zoom">
          <button
            type="button"
            className={plainButton}
            onClick={() => canvas.current?.zoomBy(1 / 1.5)}
            title="Zoom out (−)"
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
            title="Zoom in (+)"
          >
            +
          </button>
          <button
            type="button"
            className={plainButton}
            onClick={() => canvas.current?.fit()}
            title="Show everything (⇧1)"
          >
            Fit
          </button>
          <button
            type="button"
            className={plainButton}
            onClick={() => setHelpShown((shown) => !shown)}
            title="Keyboard shortcuts (?)"
            aria-pressed={helpShown}
          >
            ?
          </button>
        </div>
      </header>
      <div ref={body} className="relative flex min-h-0 flex-1">
        {sidebar.open !== false && (
          <Sidebar
            width={sidebar.width}
            onResize={sidebar.resize}
            onResized={sidebar.remember}
            // Until toggled, it shows only in wide windows.
            hiddenWhenNarrow={sidebar.open === undefined}
          >
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
            <LayersList apps={layers} selected={search.tile} onChoose={choose} />
          </Sidebar>
        )}
        <main
          className="relative min-w-0 flex-1 bg-background"
          // For what's drawn the same size at any zoom, such as the selection's outline.
          style={{ "--zoom": zoom ?? 1 } as React.CSSProperties}
        >
          <DensityContext value={density}>
            <SelectContext value={select}>
              <SelectedContext value={search.tile}>
                <StepContext value={stepScreen}>
                  <Canvas
                    width={size.width}
                    height={size.height}
                    nodes={nodes}
                    nodeTypes={nodeTypes}
                    handle={canvas}
                    onZoomChange={setZoom}
                    onPaneClick={onPaneClick}
                  />
                </StepContext>
              </SelectedContext>
            </SelectContext>
          </DensityContext>
          {tiles.length === 0 && (
            <p className="pointer-events-none absolute top-1/2 right-0 left-0 text-center text-secondary">
              {changes?.length === 0
                ? "No snapshots changed."
                : "No snapshots match these filters."}
            </p>
          )}
        </main>
        <Inspector
          tile={selected}
          // A base-side tile's file and line are the base's.
          commit={
            base !== undefined &&
            (selected?.change?.label === "Before" || selected?.change?.label === "Removed")
              ? base.commit
              : book.commit
          }
          summary={summary}
          onClose={deselect}
          onZoomTo={zoomToSelection}
        />
      </div>
      {helpShown && <ShortcutsHelp onClose={() => setHelpShown(false)} />}
    </div>
  );
}

const modes = [
  { value: "grid", name: "Grid" },
  { value: "flow", name: "Flow" },
] as const;

const arrowDirections: Partial<Record<string, Direction>> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
};

/** Whether a key goes to a panel beside the canvas, such as the inspector, which it may scroll. */
const inPanel = (target: EventTarget | null) =>
  target instanceof Element && target.closest("aside") !== null;

/** Whether a key goes to a field being typed in, rather than to the canvas. */
const isTyping = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));

/** The canvas's keyboard shortcuts, and the rest of its input, for the list `?` opens. */
const shortcuts: ReadonlyArray<readonly [keys: string, action: string]> = [
  ["← ↑ → ↓", "Select the nearest frame that way"],
  ["Esc", "Deselect"],
  ["⇧1", "Show everything"],
  ["⇧2", "Zoom to the selection"],
  ["+ and −", "Zoom in and out, with or without ⌘"],
  ["Drag or scroll", "Pan, also while holding Space"],
  ["Pinch or ⌘-scroll", "Zoom"],
  ["?", "Show or hide these shortcuts"],
];

function ShortcutsHelp({ onClose }: { readonly onClose: () => void }) {
  return (
    // A click outside it closes it.
    <div className="absolute inset-0 z-4 flex items-center justify-center" onClick={onClose}>
      <div
        role="dialog"
        aria-label="Keyboard shortcuts"
        className="w-[380px] max-w-[calc(100vw-32px)] rounded-control border border-border bg-surface p-4 shadow-popover"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="mb-3 flex items-center justify-between">
          <h2 className="text-small font-semibold">Keyboard shortcuts</h2>
          <button type="button" className={plainButton} onClick={onClose} aria-label="Close">
            ×
          </button>
        </header>
        <dl className="grid grid-cols-[auto_1fr] items-baseline gap-x-4 gap-y-2 text-small">
          {shortcuts.map(([keys, action]) => (
            <Fragment key={keys}>
              <dt>
                <kbd className="rounded-chip border border-border bg-background px-1.5 py-0.5 font-sans text-mini whitespace-nowrap">
                  {keys}
                </kbd>
              </dt>
              <dd className="text-secondary">{action}</dd>
            </Fragment>
          ))}
        </dl>
      </div>
    </div>
  );
}

/** The sidebar's width, in CSS pixels: as Linear's, and how far it can be dragged. */
const sidebarWidth = { initial: 244, min: 200, max: 400 };
/** Narrower than this, the sidebar starts hidden, so the canvas has the room. */
const narrowQuery = "(max-width: 899px)";
const widthKey = "pixelbook.sidebarWidth";

/** `localStorage`, which may be unavailable (blocked, or a sandbox): then nothing is remembered. */
const storage = {
  get: (key: string) => {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set: (key: string, value: string) => {
    try {
      localStorage.setItem(key, value);
    } catch {
      // Not remembered.
    }
  },
};

/**
 * Whether the sidebar shows, and how wide it is. `open` is `undefined` until it's toggled: then it
 * shows only in wide windows, by CSS, so it doesn't flash before the page knows the window's
 * width. Its width is remembered across visits.
 */
function useSidebar() {
  const [open, setOpen] = useState<boolean>();
  const [width, setWidth] = useState(sidebarWidth.initial);
  useEffect(() => {
    const stored = Number(storage.get(widthKey));
    if (stored >= sidebarWidth.min && stored <= sidebarWidth.max) setWidth(stored);
  }, []);
  const resize = useCallback((to: number) => {
    setWidth(Math.round(Math.min(sidebarWidth.max, Math.max(sidebarWidth.min, to))));
  }, []);
  const remember = useCallback((width: number) => storage.set(widthKey, String(width)), []);
  const toggle = useCallback(
    () => setOpen((open) => !(open ?? !window.matchMedia(narrowQuery).matches)),
    [],
  );
  return { open, width, resize, remember, toggle };
}

/**
 * The left sidebar: what to show on the canvas. Its right edge drags to resize it. Narrow windows
 * show it over the canvas.
 */
function Sidebar({
  width,
  onResize,
  onResized,
  hiddenWhenNarrow,
  children,
}: {
  readonly width: number;
  readonly onResize: (width: number) => void;
  /** Once a drag ends, with the width it ended at. */
  readonly onResized: (width: number) => void;
  readonly hiddenWhenNarrow: boolean;
  readonly children: React.ReactNode;
}) {
  const start = useRef<{ x: number; width: number } | null>(null);
  const latest = useRef(width);
  latest.current = width;
  return (
    <aside
      className={`relative flex max-w-[calc(100vw-48px)] shrink-0 border-r border-border bg-surface max-[899px]:absolute max-[899px]:inset-y-0 max-[899px]:left-0 max-[899px]:z-3 max-[899px]:shadow-popover ${hiddenWhenNarrow ? "max-[899px]:hidden" : ""}`}
      style={{ width }}
      aria-label="Filters and layers"
    >
      <div className="flex min-w-0 flex-1 flex-col gap-4 overflow-auto px-2 py-3">{children}</div>
      <div
        className="absolute inset-y-0 right-0 w-1.5 cursor-col-resize hover:bg-accent/20"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the sidebar"
        onPointerDown={(event) => {
          if (event.button !== 0 || !event.isPrimary) return;
          // Not a text selection across the sidebar.
          event.preventDefault();
          event.currentTarget.setPointerCapture(event.pointerId);
          start.current = { x: event.clientX, width };
        }}
        onPointerMove={(event) => {
          if (start.current === null) return;
          onResize(start.current.width + event.clientX - start.current.x);
        }}
        onPointerUp={() => {
          if (start.current === null) return;
          start.current = null;
          onResized(latest.current);
        }}
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
