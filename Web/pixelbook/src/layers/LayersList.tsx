// The sidebar's layers list (851-2763): apps, their screens and each screen's states, collapsible
// and searchable. Choosing a state selects it and zooms to it; selecting on the canvas shows it here.
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { badgeColors } from "../canvas/Tile.tsx";
import { ChevronIcon } from "../comps/Icons.tsx";
import { SectionTitle } from "../comps/SectionTitle.tsx";
import {
  badgeLabel,
  type LayerApp,
  type LayerState,
  layerOf,
  searchLayers,
} from "../lib/Layers.ts";

/** A row: each level indents it further. */
const row =
  "flex h-7 w-full cursor-pointer items-center gap-1.5 rounded-chip pr-2 text-left text-small hover:bg-hover";

/** Memoized: its page re-renders with each zoom. */
export const LayersList = memo(function LayersList({
  apps,
  selected,
  onChoose,
}: {
  readonly apps: ReadonlyArray<LayerApp>;
  /** The selected tile's ID. */
  readonly selected: string | undefined;
  readonly onChoose: (state: LayerState) => void;
}) {
  const [query, setQuery] = useState("");
  // Apps start open and screens closed, so the list starts as short as the screens.
  const [closedApps, setClosedApps] = useState<ReadonlySet<string>>(new Set());
  const [openScreens, setOpenScreens] = useState<ReadonlySet<string>>(new Set());
  const searching = query.trim() !== "";
  const shown = useMemo(() => searchLayers(apps, query), [apps, query]);

  // A frame selected on the canvas opens its screen here, even if closed since, and scrolls to it
  // once its row is shown; opening and closing others leaves the list where it is. Once per
  // selection: a filter gives the list new apps, which mustn't scroll it again (851-2789).
  const list = useRef<HTMLDivElement>(null);
  const place = useMemo(() => layerOf(apps, selected), [apps, selected]);
  const [revealed, setRevealed] = useState<string | undefined>(undefined);
  // Deselecting forgets it, so selecting the same frame again shows it again.
  if (selected === undefined && revealed !== undefined) setRevealed(undefined);
  const pending = revealed === selected ? undefined : place;
  const pendingApp = pending?.app;
  const pendingScreen = pending?.screen;
  const pendingState = pending?.state;
  useEffect(() => {
    if (pendingApp === undefined || pendingScreen === undefined) return;
    setClosedApps((closed) => without(closed, pendingApp));
    setOpenScreens((open) => (open.has(pendingScreen) ? open : new Set(open).add(pendingScreen)));
  }, [pendingApp, pendingScreen]);
  // After each render while it's pending: once its row is shown, scroll to it.
  useLayoutEffect(() => {
    if (pendingState === undefined) return;
    const row = list.current?.querySelector(`[data-layer="${CSS.escape(pendingState)}"]`);
    if (row === null || row === undefined) return;
    row.scrollIntoView({ block: "nearest" });
    setRevealed(selected);
  });

  return (
    <section className="flex flex-col gap-1" aria-label="Layers">
      <SectionTitle in="sidebar">Layers</SectionTitle>
      <input
        className="mx-1 mb-1 h-7 rounded-chip border border-border bg-background px-2 text-small placeholder:text-secondary focus:border-accent focus:outline-none"
        type="search"
        placeholder="Search screens and states"
        aria-label="Search screens and states"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        onKeyDown={(event) => {
          // Escape clears the search, then leaves the field.
          if (event.key !== "Escape") return;
          if (query !== "") setQuery("");
          else event.currentTarget.blur();
        }}
      />
      <div ref={list}>
        {shown.length === 0 && (
          <p className="px-2 py-1 text-secondary">{searching ? "No matches." : "Nothing here."}</p>
        )}
        {shown.map((app) => {
          const appOpen = searching || !closedApps.has(app.key);
          return (
            <div key={app.key}>
              <button
                type="button"
                className={`${row} pl-1 font-medium text-foreground`}
                aria-expanded={appOpen}
                onClick={(event) => {
                  handBack(event);
                  setClosedApps((closed) => toggled(closed, app.key));
                }}
              >
                <ChevronIcon open={appOpen} />
                <span className="truncate">{app.name}</span>
              </button>
              {appOpen &&
                app.screens.map((screen) => {
                  const screenOpen = searching || openScreens.has(screen.key);
                  return (
                    <div key={screen.key}>
                      <button
                        type="button"
                        className={`${row} pl-5 text-foreground`}
                        aria-expanded={screenOpen}
                        onClick={(event) => {
                          handBack(event);
                          setOpenScreens((open) => toggled(open, screen.key));
                        }}
                      >
                        <ChevronIcon open={screenOpen} />
                        <span className="truncate">{screen.name}</span>
                        <span className="ml-auto text-mini text-secondary tabular-nums">
                          {screen.states.length}
                        </span>
                      </button>
                      {screenOpen &&
                        screen.states.map((state) => {
                          const current = selected !== undefined && state.ids.includes(selected);
                          return (
                            <button
                              key={state.key}
                              type="button"
                              aria-current={current ? "true" : undefined}
                              data-layer={state.key}
                              className={`${row} pl-[42px] ${current ? "bg-selected text-foreground" : "text-muted"}`}
                              onClick={(event) => {
                                handBack(event);
                                onChoose(state);
                              }}
                            >
                              <span className="truncate">{state.name}</span>
                              {state.detail !== undefined && (
                                <span className="shrink-0 text-mini text-secondary">
                                  {state.detail}
                                </span>
                              )}
                              {state.badge !== undefined && (
                                <span
                                  className={`ml-auto shrink-0 rounded-full px-1.5 text-[11px] leading-4 font-semibold text-white ${badgeColors[badgeLabel[state.badge]]}`}
                                >
                                  {state.badge}
                                </span>
                              )}
                            </button>
                          );
                        })}
                    </div>
                  );
                })}
            </div>
          );
        })}
      </div>
    </section>
  );
});

/**
 * After a click, rather than a key, gives the keys back to the canvas, so the arrow keys move the
 * selection rather than scrolling the sidebar.
 */
const handBack = (event: React.MouseEvent<HTMLElement>) => {
  if (event.detail > 0) event.currentTarget.blur();
};

const toggled = (set: ReadonlySet<string>, key: string) =>
  set.has(key) ? without(set, key) : new Set(set).add(key);

const without = (set: ReadonlySet<string>, key: string) => {
  if (!set.has(key)) return set;
  const copy = new Set(set);
  copy.delete(key);
  return copy;
};
