// Pixelbook's comment on a pull request (`.github/workflows/pixelbook.yml`): how many snapshots
// changed since the PR's base, linked to the comparison. Prints the comment's Markdown.
//   node Web/pixelbook/scripts/diff.ts --base <sha> --head <sha>
import { diffBooks, summarize } from "../src/Diff.ts";
import { type Book, loadBook, NotPublished } from "../src/Snapshots.ts";

/** Where comments link to: prod's Pixelbook, which reads every commit's snapshots. */
export const pixelbookUrl = "https://pixelbook.lil.tech";

/** Marks Pixelbook's comment, so a PR has one that each push updates. */
export const marker = "<!-- pixelbook -->";

const short = (commit: string) => commit.slice(0, 7);

/** The comment for a comparison, or for a side that isn't published. */
export const comment = (
  base: string,
  head: string,
  books: { readonly base: Book | undefined; readonly head: Book | undefined },
): string => {
  if (books.head === undefined) {
    return `${marker}\n**Pixelbook** has no snapshots of ${short(head)} yet: lefthook's pre-push hook publishes them (\`scripts/pixelbook publish\`).`;
  }
  if (books.base === undefined) {
    return `${marker}\n**Pixelbook** has no snapshots of the base, ${short(base)}, to compare with. [Snapshots of ${short(head)}](${pixelbookUrl}/?commit=${head})`;
  }
  const summary = summarize(diffBooks(books.base, books.head));
  const link = `${pixelbookUrl}/?commit=${head}&base=${base}`;
  if (summary.changed + summary.added + summary.removed === 0) {
    return `${marker}\n**Pixelbook**: no snapshots changed since ${short(base)}. [All snapshots](${pixelbookUrl}/?commit=${head})`;
  }
  const parts = [
    summary.changed > 0 ? `${summary.changed} changed` : undefined,
    summary.added > 0 ? `${summary.added} new` : undefined,
    summary.removed > 0 ? `${summary.removed} removed` : undefined,
  ].filter((part) => part !== undefined);
  const screens = `${summary.screens} ${summary.screens === 1 ? "screen" : "screens"}`;
  return `${marker}\n**Pixelbook**: ${parts.join(", ")} on ${screens} since ${short(base)}. [See what changed](${link})`;
};

const load = (commit: string) =>
  loadBook({ commit }).catch((error: unknown) => {
    if (error instanceof NotPublished) return undefined;
    throw error;
  });

const argument = (name: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
};

if (import.meta.main) {
  const base = argument("base");
  const head = argument("head");
  if (base === undefined || head === undefined) {
    throw new Error("usage: node Web/pixelbook/scripts/diff.ts --base <sha> --head <sha>");
  }
  const [baseBook, headBook] = await Promise.all([load(base), load(head)]);
  console.log(comment(base, head, { base: baseBook, head: headBook }));
}
