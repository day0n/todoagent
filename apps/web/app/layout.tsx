import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { WorkspaceShell } from "../components/shell.tsx";

/**
 * Geist Sans and Geist Mono.
 *
 * The reference site computes `GeistSans` for body text, and it is the natural
 * pairing for a white shadcn/zinc surface. Both ship inside next/font/google, so
 * this needs no extra dependency and is self-hosted and preloaded — the weights
 * this UI leans on are present on first paint instead of swapping in late.
 *
 * The mono face is not decorative here: transcripts, diffs, repo paths and agent
 * ids all need columns that line up.
 */
const geistSans = Geist({
  subsets: ["latin"],
  variable: "--font-geist-sans",
  display: "swap",
});

const geistMono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-geist-mono",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Council",
  description:
    "把本地的 Claude / Codex / Cursor / Kiro / Grok 组成一支有分工、会互相挑错的专家团队。",
};

export const viewport: Viewport = {
  // The app is light-only, so the browser chrome is pinned to the same white
  // rather than following the OS into a colour the UI never uses.
  themeColor: "#ffffff",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN" className={`${geistSans.variable} ${geistMono.variable}`}>
      {/*
        Fixed, non-scrolling body. The workspace is a shell — icon rail, channel
        sidebar, panel with its own scroll region — like a chat client, not a
        document that scrolls as a whole.

        `h-dvh` rather than `h-screen`: on mobile Safari the latter is the larger
        viewport, so the composer at the bottom of a channel ends up under the
        browser's own toolbar.
      */}
      <body className="h-dvh overflow-hidden">
        <WorkspaceShell>{children}</WorkspaceShell>
      </body>
    </html>
  );
}
