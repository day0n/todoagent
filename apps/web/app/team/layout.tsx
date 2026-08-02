import Link from "next/link";
import { IconBack } from "../../components/icons.tsx";

/**
 * Scroll container for the team page, plus the way back.
 *
 * `body` is a flex row holding the three panes, so a route rendered into it needs
 * to declare itself the flexible column — otherwise there is no height to scroll
 * within and the content is clipped at the fold.
 *
 * The back link lives here rather than on the page because this route is reached
 * from the sidebar gear, which slides out of view once you arrive: without it the
 * only route home is the browser's own back button.
 */
export default function TeamLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="page">
      <div className="page-in" style={{ paddingTop: 26 }}>
        <Link href="/" className="backlink">
          <IconBack />
          任务
        </Link>
        {children}
      </div>
    </div>
  );
}
