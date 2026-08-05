/**
 * Client-side image prep for chat attachments.
 *
 * A picture pasted straight off a phone can be 4000px and several megabytes —
 * fine for local storage, wasteful to ship to a vision model that resizes it
 * server-side anyway. Shrinking here means a smaller upload, a smaller
 * `agent_chat.attachments` payload, and a smaller thing the model has to
 * actually look at.
 */

export interface ResizedImage {
  mediaType: string;
  /** Base64, no `data:` prefix — what the engine's `/api/chat` expects. */
  data: string;
  width: number;
  height: number;
}

/** Media types the engine's upload path (and most vision models) accept. */
export const ACCEPTED_IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif"] as const;
export type AcceptedImageType = (typeof ACCEPTED_IMAGE_TYPES)[number];

export function isAcceptedImageType(mediaType: string): mediaType is AcceptedImageType {
  return (ACCEPTED_IMAGE_TYPES as readonly string[]).includes(mediaType);
}

/**
 * The target size for a resize, given the source dimensions.
 *
 * Pure so the aspect-ratio math can be tested without a real `<canvas>`. Two
 * invariants worth pinning: it never upscales — a 400px icon does not become a
 * blurry 1600px image — and it always returns whole pixels, since a canvas
 * cannot be drawn at a fractional size.
 */
export function computeResizedDimensions(
  width: number,
  height: number,
  maxEdge = 1600,
): { width: number; height: number } {
  const longEdge = Math.max(width, height);
  if (longEdge <= maxEdge) return { width: Math.round(width), height: Math.round(height) };
  const scale = maxEdge / longEdge;
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

/**
 * Splits a `data:` URL into what `/api/chat` wants.
 *
 * `canvas.toDataURL()` is the browser's only synchronous way to get base64 out
 * of a canvas, but it always prepends `data:<type>;base64,` — a prefix the
 * engine's `images[].data` field must NOT carry (it decodes with
 * `Buffer.from(data, "base64")`, which a `data:` prefix would corrupt).
 */
export function parseDataUrl(dataUrl: string): { mediaType: string; data: string } | null {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(dataUrl);
  if (m === null) return null;
  const mediaType = m[1];
  const data = m[2];
  if (mediaType === undefined || data === undefined || data === "") return null;
  return { mediaType, data };
}

/**
 * Loads an image `File`/`Blob`, downsizes it to `maxEdge` on its long side,
 * and returns base64 bytes ready for `api.chatSend`.
 *
 * Re-encoded as PNG unconditionally, not the source's own type: canvas has no
 * "keep whatever this was" mode, only "pick one format to draw out as", and
 * PNG needs no quality parameter to reason about. Chat photos are for the
 * model to read, not a gallery to archive at maximum fidelity.
 */
export async function resizeImageFile(file: Blob, maxEdge = 1600): Promise<ResizedImage> {
  const objectUrl = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image();
      el.onload = () => resolve(el);
      el.onerror = () => reject(new Error("图片解码失败"));
      el.src = objectUrl;
    });

    const { width, height } = computeResizedDimensions(img.naturalWidth, img.naturalHeight, maxEdge);
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    if (ctx === null) throw new Error("canvas 不可用");
    ctx.drawImage(img, 0, 0, width, height);

    const parsed = parseDataUrl(canvas.toDataURL("image/png"));
    if (parsed === null) throw new Error("图片编码失败");
    return { mediaType: parsed.mediaType, data: parsed.data, width, height };
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}
