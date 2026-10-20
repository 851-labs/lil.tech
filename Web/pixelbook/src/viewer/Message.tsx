/** A page in place of the viewer, saying why: nothing published, or snapshots that didn't load. */
export function Message({ children }: { readonly children: React.ReactNode }) {
  return (
    <main className="mx-auto my-[120px] max-w-[560px] px-6 text-secondary [&_p]:my-[1em]">
      <h1 className="my-[0.67em] text-[2em] font-bold text-foreground">Pixelbook</h1>
      {children}
    </main>
  );
}
