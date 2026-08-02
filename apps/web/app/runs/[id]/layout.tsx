/**
 * Scroll container for the run detail page.
 *
 * `body` is a flex row holding the three panes, so a route rendered into it needs
 * to declare itself the flexible column — otherwise the page has no height to
 * scroll within and the content is simply clipped at the fold.
 *
 * No back link here: the page already renders its own next to the run title.
 */
export default function RunLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="page">
      <div className="page-in">{children}</div>
    </div>
  );
}
