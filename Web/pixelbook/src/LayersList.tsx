// The sidebar's layers list (851-2763): apps, their screens and each screen's states, collapsible
// and searchable. Choosing a state selects it and zooms to it; selecting on the canvas shows it here.
import { memo, useEffect, useMemo, useRef, useState } from "react";
import { badgeLabel, type LayerApp, type LayerState, layerOf, searchLayers } from "./Layers.ts";
import { badgeColors } from "./Tiles.tsx";

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
  // once it's open; opening and closing others leaves the list where it is. Only once per
  // selection: a filter gives the list new apps, which mustn't scroll it again (851-2789).
  const list = useRef<HTMLDivElement>(null);
  const place = useMemo(() => layerOf(apps, selected), [apps, selected]);
  const revealed = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (place === undefined || revealed.current === selected) return;
    setClosedApps((closed) => without(closed, place.app));
    setOpenScreens((open) => (open.has(place.screen) ? open : new Set(open).add(place.screen)));
    // Once its row is shown: a screen just opened may take a few frames. Noted once it scrolls,
    // so a filter changed before then doesn't lose it.
    let frames = 0;
    let next = requestAnimationFrame(function reveal() {
      const row = list.current?.querySelector(`[data-layer="${CSS.escape(place.state)}"]`);
      if (row === null || row === undefined) {
        if (++frames < 30) next = requestAnimationFrame(reveal);
        return;
      }
      revealed.current = selected;
      row.scrollIntoView({ block: "nearest" });
    });
    return () => cancelAnimationFrame(next);
  }, [place, selected]);

  return (
    <section className="flex flex-col gap-1" aria-label="Layers">
      <h2 className="px-2 pb-1 text-mini font-medium text-secondary">Layers</h2>
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
                <Chevron open={appOpen} />
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
                        <Chevron open={screenOpen} />
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

function Chevron({ open }: { readonly open: boolean }) {
  return (
    <svg
      className={`size-3 shrink-0 text-secondary transition-transform ${open ? "rotate-90" : ""}`}
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden="true"
    >
      <path d="M4.5 3 7.5 6l-3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

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
