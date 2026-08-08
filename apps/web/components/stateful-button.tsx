"use client";

import type { ButtonHTMLAttributes, ReactNode } from "react";

/** A controlled adaptation of Aceternity UI's Stateful Button. */
export function StatefulButton({
  pending,
  children,
  pendingLabel = "正在处理…",
  className = "",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  pending: boolean;
  pendingLabel?: string;
  children: ReactNode;
}) {
  return (
    <button
      {...props}
      className={`stateful-button ${className}`.trim()}
      aria-busy={pending}
      disabled={props.disabled || pending}
    >
      <span className={`stateful-button-content${pending ? " pending" : ""}`}>
        {pending ? <i className="stateful-button-spinner" aria-hidden="true" /> : null}
        <span>{pending ? pendingLabel : children}</span>
      </span>
    </button>
  );
}
