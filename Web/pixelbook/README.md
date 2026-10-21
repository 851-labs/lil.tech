# Pixelbook

The viewer for the apps' preview snapshots, deployed to `pixelbook.lil.tech`. Run it with `vp dev`. `docs/decisions/pixelbook.md` says how it works and why.

## Where code goes

In `src/`:

- `routes/`: TanStack Router's file routes, kept thin: a route's search, loader and error pages, rendering a page from elsewhere. `routeTree.gen.ts` is generated from them, and `router.tsx` and `styles.css` stay where the TanStack Start plugin and the root route look for them.
- `comps/`: reusable building blocks, one component per file named after it (`Button.tsx`, `Segmented.tsx`, `Sidebar.tsx`…), with no knowledge of snapshots. Use them before writing another button or class string; add a variant or prop when one is nearly right.
- A folder per feature for the pieces only it uses: `viewer/` (the page, its header's and sidebar's parts), `canvas/` (the React Flow canvas and the nodes both modes show), `flow/` (flowchart nodes), `inspector/` and `layers/`.
- `hooks/`: React hooks, one per file (`useSidebar.ts`).
- `lib/`: logic that isn't UI, such as loading snapshots, layouts, filters, selection and diffs, in plain `.ts` with tests in `test/`. It doesn't import React components, and `scripts/` run some of it under Node.
