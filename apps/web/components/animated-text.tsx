"use client";

import { Calligraph, type CalligraphProps } from "calligraph";
import { useSyncExternalStore } from "react";

type AnimatedTextProps = Pick<
  CalligraphProps,
  "animation" | "autoSize" | "className" | "drift" | "stagger" | "trend" | "variant"
> & {
  children: string | number;
};

const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";

function subscribeToReducedMotion(onChange: () => void): () => void {
  const media = window.matchMedia(REDUCED_MOTION_QUERY);
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
}

function reducedMotionSnapshot(): boolean {
  return window.matchMedia(REDUCED_MOTION_QUERY).matches;
}

/**
 * Calligraph with a real accessibility fallback.
 *
 * Motion is useful for state changes, but a person who asks the OS to reduce
 * motion should receive the same content as an ordinary span. Starting with the
 * static server snapshot also prevents the first hydration from animating.
 */
export function AnimatedText({
  children,
  animation = "smooth",
  autoSize = false,
  className,
  drift = { x: 7, y: 0 },
  stagger = 0.012,
  trend = 0,
  variant = "text",
}: AnimatedTextProps) {
  const reduceMotion = useSyncExternalStore(
    subscribeToReducedMotion,
    reducedMotionSnapshot,
    () => true,
  );

  if (reduceMotion) return <span className={className}>{children}</span>;

  return (
    <Calligraph
      // Calligraph 1.4.1 briefly renders missing character keys when a text
      // update also changes its length. Remounting only for that boundary keeps
      // equal-length morphs fluid and avoids a React 19 warning; number mode has
      // its own positional keying and does not need this guard.
      key={variant === "text" ? String(children).length : undefined}
      animation={animation}
      autoSize={autoSize}
      className={className}
      drift={drift}
      stagger={stagger}
      trend={trend}
      variant={variant}
    >
      {children}
    </Calligraph>
  );
}
