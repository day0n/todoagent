import type { Metadata, Viewport } from "next";
import "./globals.css";
import { MotionProvider } from "../components/motion-provider.tsx";

/**
 * Root layout.
 *
 * Deliberately thin: `body` is itself the three-pane flex container (see
 * globals.css), so the home page renders the sidebar, task pane and chat pane as
 * its direct children. There is no shell component wrapping every route — the
 * previous one drew an icon rail and a channel sidebar that no longer exist, and
 * the two secondary pages opt into `.page` instead.
 *
 * No `next/font` here either. The prototype's type is the system stack
 * (-apple-system → PingFang SC), which is what a Mac-native-feeling app should
 * use and which needs no download; the two Geist faces this used to load existed
 * for a design that is gone.
 */

export const metadata: Metadata = {
  title: "TodoAgent",
  description: "一个会自己完成任务的待办清单。",
};

export const viewport: Viewport = {
  // Matches the desktop grey the panes sit on, so the browser chrome does not
  // frame the app in a colour it never uses.
  themeColor: "#f3f3f5",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN">
      <body>
        <MotionProvider>{children}</MotionProvider>
      </body>
    </html>
  );
}
