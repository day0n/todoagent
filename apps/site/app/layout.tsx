import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { IBM_Plex_Mono, Noto_Sans_SC } from "next/font/google";
import "./globals.css";

const sans = Noto_Sans_SC({
  subsets: ["latin"],
  variable: "--font-sans",
  display: "swap",
  weight: ["400", "500", "600", "700"],
});

const mono = IBM_Plex_Mono({
  subsets: ["latin"],
  variable: "--font-mono",
  display: "swap",
  weight: ["400", "500"],
});

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#e9eaed",
};

const title = "TodoAgent — 一个任务。一条终端。一个 Agent。";
const description =
  "打开任务，就绑定一条还活着的终端。在这个目录里启动 Codex、Claude Code、Cursor Agent 或 Kiro CLI。清单交给 TodoAgent。";

export const metadata: Metadata = {
  metadataBase: new URL("https://todoagent.space"),
  title,
  description,
  applicationName: "TodoAgent",
  keywords: ["TodoAgent", "macOS", "Coding Agent", "待办", "终端", "Ghostty"],
  authors: [{ name: "TodoAgent", url: "https://github.com/day0n/todoagent" }],
  creator: "TodoAgent",
  alternates: { canonical: "/" },
  icons: {
    icon: "/todoagent-icon.png",
    apple: "/todoagent-icon.png",
  },
  openGraph: {
    type: "website",
    url: "/",
    siteName: "TodoAgent",
    locale: "zh_CN",
    title,
    description,
    images: [
      {
        url: "/shots/workspace.png",
        width: 2000,
        height: 1295,
        alt: "任务绑定的 TodoAgent 本机终端",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
    images: ["/shots/workspace.png"],
  },
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="zh-CN" className={`${sans.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}
