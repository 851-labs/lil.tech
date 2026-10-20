// The viewer (851-2700): the page that shows a book of snapshots, as a grid or a flowchart, or what
// changed since a base.
import { getRouteApi } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Canvas, type CanvasHandle, type Insets } from "../canvas/Canvas.tsx";
import { LabelNodeView } from "../canvas/LabelNode.tsx";
import { DensityContext, SelectContext, SelectedContext, TileNodeView } from "../canvas/Tile.tsx";
import { Button } from "../comps/Button.tsx";
import { ExternalLink } from "../comps/ExternalLink.tsx";
import { SidebarIcon } from "../comps/Icons.tsx";
import { Segmented } from "../comps/Segmented.tsx";
import { Sidebar } from "../comps/Sidebar.tsx";
import { RoutesNodeView } from "../flow/RoutesNode.tsx";
import { ScreenNodeView } from "../flow/ScreenNode.tsx";
import { StepContext } from "../flow/StepContext.ts";
import { useDevicePixelRatio } from "../hooks/useDevicePixelRatio.ts";
import { useSidebar } from "../hooks/useSidebar.ts";
import { useSteps } from "../hooks/useSteps.ts";
import { Inspector, type Summary } from "../inspector/Inspector.tsx";
import { LayersList } from "../layers/LayersList.tsx";
import { describeChanges, diffBooks, layoutDiff, shownChanges, summarize } from "../lib/Diff.ts";
import { flowNodes, gridNodes, withSteps } from "../lib/Elements.ts";
import { filtersFrom, modeFrom, type SearchChange, toggle, withChange } from "../lib/Filters.ts";
import { layoutFlowchart } from "../lib/Flow.ts";
import { graphs } from "../lib/graphs.ts";
import { layoutGrid, type Tile, tileId } from "../lib/Grid.ts";
import { arrowDirections, inPanel, isTyping } from "../lib/Keys.ts";
import { flowLayers, gridLayers, type LayerState } from "../lib/Layers.ts";
import { flowFrames, frameOf, gridFrames, neighbor } from "../lib/Selection.ts";
import {
  appName,
  commitUrl,
  compareUrl,
  manifestPlatform,
  platformNames,
  platforms,
  schemeNames,
  schemes,
  tileDensity,
} from "../lib/Snapshots.ts";
import { FilterList } from "./FilterList.tsx";
import { ShortcutsHelp } from "./ShortcutsHelp.tsx";

/** The route it's the page of (`routes/index.tsx`), without importing it, which imports this. */
const route = getRouteApi("/");

const nodeTypes = {
  tile: TileNodeView,
  label: LabelNodeView,
  screen: ScreenNodeView,
  routes: RoutesNodeView,
};

/**
 * The page: a header, the sidebar's filters and layers, the canvas in either mode, and the
 * inspector.
 */
export function Viewer() {
  const { book, base, missingBase } = route.useLoaderData();
  const search = route.useSearch();
  const navigate = route.useNavigate();
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
        <Button
          className="border-transparent px-1.5"
          onClick={sidebar.toggle}
          title="Show or hide the sidebar"
        >
          <SidebarIcon />
        </Button>
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
            <Button onClick={() => setSearch({ base: undefined })}>Show all</Button>
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
            <Button onClick={() => setSearch({ base: undefined, tile: undefined })}>
              Show all
            </Button>
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
          <Button onClick={() => canvas.current?.zoomBy(1 / 1.5)} title="Zoom out (−)">
            −
          </Button>
          <span className="min-w-10 text-center text-mini text-secondary tabular-nums">
            {zoom === undefined ? "" : `${Math.round(zoom * 100)}%`}
          </span>
          <Button onClick={() => canvas.current?.zoomBy(1.5)} title="Zoom in (+)">
            +
          </Button>
          <Button onClick={() => canvas.current?.fit()} title="Show everything (⇧1)">
            Fit
          </Button>
          <Button
            onClick={() => setHelpShown((shown) => !shown)}
            title="Keyboard shortcuts (?)"
            aria-pressed={helpShown}
          >
            ?
          </Button>
        </div>
      </header>
      <div ref={body} className="relative flex min-h-0 flex-1">
        {sidebar.open !== false && (
          <Sidebar
            label="Filters and layers"
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
