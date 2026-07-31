import type { Metadata, Viewport } from "next";
import { Space_Grotesk } from "next/font/google";
import "./globals.css";
import { WorkspaceShell } from "../components/shell.tsx";

/**
 * Space Grotesk, the face Raft's app actually loads.
 *
 * Extracted from their computed styles: `"Raft Quote Glyphs", "Space Grotesk",
 * system-ui` with weights 400/500/600/700 in the document's font set. The first
 * family is their private glyph pack, which is not distributable; Space Grotesk is
 * the public face doing the real work.
 *
 * Loading it via next/font rather than a stylesheet link means it is self-hosted and
 * preloaded, so the heavy 700 weight this design leans on is present on first paint
 * instead of swapping in late.
 */
const spaceGrotesk = Space_Grotesk({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-space-grotesk",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Council",
  description:
    "把本地的 Claude / Codex / Cursor / Kiro / Grok 组成一支有分工、会互相挑错的专家团队。",
};

export const viewport: Viewport = {
  themeColor: "#ffd440",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN" className={spaceGrotesk.variable}>
      {/*
        Full-height, non-scrolling body. The workspace is a fixed shell — rail,
        header, scrolling content — like a chat client, not a document that scrolls
        as a whole.
      */}
      <body className="h-screen overflow-hidden">
        <WorkspaceShell>{children}</WorkspaceShell>
      </body>
    </html>
  );
}
