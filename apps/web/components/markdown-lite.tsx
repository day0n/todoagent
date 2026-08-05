/**
 * A deliberately small Markdown subset, for the secretary's replies only.
 *
 * vercel/chatbot's message list leans on `react-markdown` + `remark-gfm`, which is
 * the right call for a document-shaped chat but drags in a full CommonMark parser
 * (remark, rehype, unified — tens of a bundle's kilobytes) for what the secretary
 * actually sends: short turns with the occasional list, code span, or link. Every
 * icon in this app is hand-drawn for the same reason (see `icons.tsx`) — nine
 * glyphs did not justify an icon library, and a handful of Markdown constructs did
 * not justify a document parser.
 *
 * Covers fenced code blocks, inline code, **bold**, *italic*, [text](url) and bare
 * URLs, and `-`/`*`/`1.` lists. Anything else (tables, nested blockquotes, HTML)
 * falls through as plain text — a readable degradation, not a broken render.
 *
 * User messages are never run through this: a person's own literal `*` or a
 * stray `_id_` should not turn into emphasis under them without asking.
 */

import type { ReactNode } from "react";
import { Fragment } from "react";

type Block =
  | { kind: "p"; text: string }
  | { kind: "code"; lang: string; code: string }
  | { kind: "list"; ordered: boolean; items: string[] };

const FENCE_RE = /^```\s*(\S*)\s*$/;
const LIST_RE = /^(\s*)([-*+]|\d+\.)\s+(.*)$/;

/** Splits a message body into block-level chunks: paragraphs, code fences, lists. */
function toBlocks(body: string): Block[] {
  const lines = body.split("\n");
  const blocks: Block[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? "";

    const fence = FENCE_RE.exec(line);
    if (fence !== null) {
      const lang = fence[1] ?? "";
      const code: string[] = [];
      i += 1;
      while (i < lines.length && FENCE_RE.exec(lines[i] ?? "") === null) {
        code.push(lines[i] ?? "");
        i += 1;
      }
      i += 1; // the closing fence, if the block was ever closed
      blocks.push({ kind: "code", lang, code: code.join("\n") });
      continue;
    }

    const firstItem = LIST_RE.exec(line);
    if (firstItem !== null) {
      const ordered = /\d/.test(firstItem[2] ?? "");
      const items: string[] = [firstItem[3] ?? ""];
      i += 1;
      for (; i < lines.length; i++) {
        const m = LIST_RE.exec(lines[i] ?? "");
        if (m === null) break;
        items.push(m[3] ?? "");
      }
      blocks.push({ kind: "list", ordered, items });
      continue;
    }

    if (line.trim() === "") {
      i += 1;
      continue;
    }

    const para: string[] = [line];
    i += 1;
    for (; i < lines.length; i++) {
      const next = lines[i] ?? "";
      if (next.trim() === "" || FENCE_RE.exec(next) !== null || LIST_RE.exec(next) !== null) break;
      para.push(next);
    }
    blocks.push({ kind: "p", text: para.join("\n") });
  }

  return blocks;
}

/**
 * One inline pass, precedence left to right in the alternation: code spans win
 * over emphasis (so `**not bold**` inside backticks stays literal), and a bare
 * URL is only tried once nothing better already matched at that position.
 */
const INLINE_RE =
  /`([^`\n]+)`|\*\*([^*\n]+)\*\*|\*([^*\n]+)\*|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<]+[^\s<.,:;!?"')\]])/g;

function renderInline(text: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let key = 0;

  for (const m of text.matchAll(INLINE_RE)) {
    const idx = m.index ?? 0;
    if (idx > last) out.push(text.slice(last, idx));
    const [, codeSpan, bold, italic, linkText, linkHref, bareUrl] = m;
    if (codeSpan !== undefined) out.push(<code key={key++}>{codeSpan}</code>);
    else if (bold !== undefined) out.push(<strong key={key++}>{bold}</strong>);
    else if (italic !== undefined) out.push(<em key={key++}>{italic}</em>);
    else if (linkText !== undefined && linkHref !== undefined)
      out.push(
        <a key={key++} href={linkHref} target="_blank" rel="noreferrer noopener">
          {linkText}
        </a>,
      );
    else if (bareUrl !== undefined)
      out.push(
        <a key={key++} href={bareUrl} target="_blank" rel="noreferrer noopener">
          {bareUrl}
        </a>,
      );
    last = idx + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** A paragraph's own newlines are soft breaks — the sender's line wrapping, kept. */
function renderParagraph(text: string): ReactNode[] {
  const lines = text.split("\n");
  return lines.flatMap((line, i) => (i === 0 ? renderInline(line) : [<br key={`br${i}`} />, ...renderInline(line)]));
}

export function MarkdownLite({ text }: { text: string }) {
  const blocks = toBlocks(text);
  // A body with no recognisable block structure at all (the common case: one
  // short line) skips the wrapper's block spacing entirely, matching how the
  // plain-text bubble rendered before this component existed.
  if (blocks.length === 1 && blocks[0]?.kind === "p" && !blocks[0].text.includes("\n")) {
    return <Fragment>{renderInline(blocks[0].text)}</Fragment>;
  }

  return (
    <div className="md">
      {blocks.map((b, i) => {
        if (b.kind === "code") {
          return (
            <pre key={i}>
              <code>{b.code}</code>
            </pre>
          );
        }
        if (b.kind === "list") {
          const items = b.items.map((item, j) => <li key={j}>{renderInline(item)}</li>);
          return b.ordered ? <ol key={i}>{items}</ol> : <ul key={i}>{items}</ul>;
        }
        return <p key={i}>{renderParagraph(b.text)}</p>;
      })}
    </div>
  );
}
