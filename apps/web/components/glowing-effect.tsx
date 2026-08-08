"use client";

import { memo, useCallback, useEffect, useRef } from "react";

/** A CSS-token adaptation of Aceternity UI's free Glowing Effect. */
export const GlowingEffect = memo(function GlowingEffect({
  active = true,
  proximity = 56,
  spread = 34,
}: {
  active?: boolean;
  proximity?: number;
  spread?: number;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const frame = useRef<number>(0);

  const update = useCallback((event?: PointerEvent) => {
    const element = ref.current;
    if (element === null) return;
    cancelAnimationFrame(frame.current);
    frame.current = requestAnimationFrame(() => {
      const rect = element.getBoundingClientRect();
      if (event === undefined) {
        element.style.setProperty("--glow-active", ".24");
        return;
      }
      // Brighter near an edge, quieter in the middle. This preserves the
      // directional shimmer without turning the whole card into a neon surface.
      const edgeDistance = Math.max(
        0,
        Math.min(
          event.clientX - rect.left,
          rect.right - event.clientX,
          event.clientY - rect.top,
          rect.bottom - event.clientY,
        ),
      );
      const intensity = Math.max(0.42, 1 - edgeDistance / Math.max(proximity, 1));
      element.style.setProperty("--glow-active", String(intensity));
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const angle = (Math.atan2(event.clientY - y, event.clientX - x) * 180) / Math.PI + 90;
      element.style.setProperty("--glow-angle", `${angle}deg`);
    });
  }, [proximity]);

  useEffect(() => {
    if (!active) return;
    if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const surface = ref.current?.parentElement;
    if (surface === null || surface === undefined) return;
    const onMove = (event: PointerEvent) => update(event);
    const onLeave = () => update();
    // Listen only while this card is actually under the pointer. The previous
    // document-level listener was duplicated once per live card and made every
    // mouse move perform needless layout reads across the whole board.
    surface.addEventListener("pointermove", onMove, { passive: true });
    surface.addEventListener("pointerleave", onLeave);
    return () => {
      cancelAnimationFrame(frame.current);
      surface.removeEventListener("pointermove", onMove);
      surface.removeEventListener("pointerleave", onLeave);
    };
  }, [active, update]);

  if (!active) return null;
  return (
    <div
      ref={ref}
      className="aceternity-glow"
      style={{ "--glow-spread": `${spread}deg` } as React.CSSProperties}
      aria-hidden="true"
    />
  );
});
