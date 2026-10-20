import { createFileRoute, notFound } from "@tanstack/react-router";
import { validateSearch } from "../lib/Filters.ts";
import { loadBook, NotPublished, sourceOf } from "../lib/Snapshots.ts";
import { Message } from "../viewer/Message.tsx";
import { Viewer } from "../viewer/Viewer.tsx";

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
  component: Viewer,
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
