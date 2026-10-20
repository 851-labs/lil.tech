// Pixelbook's icons, drawn in the text's color.

/** The header's button that shows or hides the sidebar. */
export function SidebarIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" />
      <path d="M6 2.5v11" stroke="currentColor" />
    </svg>
  );
}

/** A disclosure triangle's chevron, pointing down when `open`. */
export function ChevronIcon({ open }: { readonly open: boolean }) {
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

/** A checkbox's check mark. */
export function CheckIcon() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
      <path d="M2 5.2 4.1 7.3 8 2.8" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}
