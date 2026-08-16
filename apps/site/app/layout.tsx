import type { Metadata } from "next";
import type { ReactNode } from "react";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://todoagent.space"),
  title: "TodoAgent — Tasks, terminals, and agents. Together.",
  description:
    "A local-first, native macOS workspace for your tasks and the coding agents you already use.",
  applicationName: "TodoAgent",
  keywords: ["TodoAgent", "macOS", "coding agents", "task manager", "terminal", "Ghostty"],
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
    title: "TodoAgent — Tasks, terminals, and agents. Together.",
    description: "A local-first, native macOS workspace for your tasks and the coding agents you already use.",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "TodoAgent — Tasks, terminals, and agents. Together.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "TodoAgent — Tasks, terminals, and agents. Together.",
    description: "A local-first, native macOS workspace for your tasks and the coding agents you already use.",
    images: ["/og.png"],
  },
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
