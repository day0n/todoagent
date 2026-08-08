"use client";

import { MotionConfig } from "motion/react";

/** Keep CSS and JavaScript motion aligned with the visitor's OS preference. */
export function MotionProvider({ children }: { children: React.ReactNode }) {
  return <MotionConfig reducedMotion="user">{children}</MotionConfig>;
}
