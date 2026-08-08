"use client";

import type { CSSProperties, PointerEvent, ReactNode } from "react";
import { useCallback, useRef } from "react";

export function EdgeGlow({
  children,
  className = "",
  active = false,
}: {
  children: ReactNode;
  className?: string;
  active?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const onPointerMove = useCallback((event: PointerEvent<HTMLDivElement>) => {
    const surface = ref.current;
    const rect = surface?.getBoundingClientRect();
    if (!surface || !rect) return;
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    const dx = x - rect.width / 2;
    const dy = y - rect.height / 2;
    const scaleX = dx === 0 ? Number.POSITIVE_INFINITY : rect.width / 2 / Math.abs(dx);
    const scaleY = dy === 0 ? Number.POSITIVE_INFINITY : rect.height / 2 / Math.abs(dy);
    const proximity = Math.min(Math.max(1 / Math.min(scaleX, scaleY), 0), 1);
    const angle = Math.atan2(dy, dx) * (180 / Math.PI) + 90;
    surface.style.setProperty("--edge-proximity", `${(proximity * 100).toFixed(3)}`);
    surface.style.setProperty("--cursor-angle", `${(angle < 0 ? angle + 360 : angle).toFixed(3)}deg`);
  }, []);

  return (
    <div
      ref={ref}
      className={`agent-edge-glow${active ? " active" : ""} ${className}`.trim()}
      onPointerMove={onPointerMove}
      onPointerLeave={() => ref.current?.style.setProperty("--edge-proximity", "0")}
      style={
        {
          "--edge-glow-one": "#c084fc",
          "--edge-glow-two": "#f472b6",
          "--edge-glow-three": "#38bdf8",
        } as CSSProperties
      }
    >
      <span className="agent-edge-light" aria-hidden="true" />
      <div className="agent-edge-content">{children}</div>
    </div>
  );
}
