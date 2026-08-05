import assert from "node:assert/strict";
import { test } from "node:test";
import { computeResizedDimensions, isAcceptedImageType, parseDataUrl } from "./image.ts";

/**
 * Tests for the pure halves of client-side image prep — the parts that do not
 * need a real `<canvas>` or `Image`, and so can run under plain `node --test`
 * rather than a browser test runner.
 */

// ── computeResizedDimensions ─────────────────────────────────

test("computeResizedDimensions: a large landscape image is capped on its long edge", () => {
  const { width, height } = computeResizedDimensions(4000, 2000, 1600);
  assert.equal(width, 1600);
  assert.equal(height, 800);
});

test("computeResizedDimensions: a large portrait image is capped on its long edge (height)", () => {
  const { width, height } = computeResizedDimensions(2000, 4000, 1600);
  assert.equal(width, 800);
  assert.equal(height, 1600);
});

test("computeResizedDimensions: a small image is never upscaled", () => {
  // A 400px icon staying 400px is the point — blowing it up to 1600px would
  // ship four times the bytes for a blurrier picture.
  const result = computeResizedDimensions(400, 300, 1600);
  assert.deepEqual(result, { width: 400, height: 300 });
});

test("computeResizedDimensions: exactly at the cap is left alone", () => {
  assert.deepEqual(computeResizedDimensions(1600, 1200, 1600), { width: 1600, height: 1200 });
});

test("computeResizedDimensions: dimensions are always whole pixels", () => {
  // 1000x777 at a 1600 cap needs no scaling, but an odd source that DOES
  // scale must not hand a canvas a fractional width — it silently floors,
  // making the caller's `canvas.width = result.width` wrong by construction.
  const { width, height } = computeResizedDimensions(3333, 1111, 1000);
  assert.equal(Number.isInteger(width), true);
  assert.equal(Number.isInteger(height), true);
  assert.equal(width, 1000);
  assert.equal(height, 333);
});

test("computeResizedDimensions: a square image scales evenly", () => {
  assert.deepEqual(computeResizedDimensions(3200, 3200, 1600), { width: 1600, height: 1600 });
});

// ── parseDataUrl ──────────────────────────────────────────────

test("parseDataUrl: splits a canvas data URL into mediaType and bare base64", () => {
  const result = parseDataUrl("data:image/png;base64,iVBORw0KGgo=");
  assert.deepEqual(result, { mediaType: "image/png", data: "iVBORw0KGgo=" });
});

test("parseDataUrl: rejects a string with no data: prefix", () => {
  assert.equal(parseDataUrl("iVBORw0KGgo="), null);
});

test("parseDataUrl: rejects a data URL with no base64 payload", () => {
  assert.equal(parseDataUrl("data:image/png;base64,"), null);
});

test("parseDataUrl: rejects a non-base64 data URL", () => {
  assert.equal(parseDataUrl("data:text/plain,hello"), null);
});

// ── isAcceptedImageType ───────────────────────────────────────

test("isAcceptedImageType: accepts the four types the engine stores", () => {
  assert.equal(isAcceptedImageType("image/png"), true);
  assert.equal(isAcceptedImageType("image/jpeg"), true);
  assert.equal(isAcceptedImageType("image/webp"), true);
  assert.equal(isAcceptedImageType("image/gif"), true);
});

test("isAcceptedImageType: refuses everything else, PDFs included", () => {
  assert.equal(isAcceptedImageType("application/pdf"), false);
  assert.equal(isAcceptedImageType("image/svg+xml"), false);
  assert.equal(isAcceptedImageType(""), false);
});
