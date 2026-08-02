/**
 * Inline icons, in the prototype's thin-geometric style.
 *
 * Hand-written rather than pulled from a library: there are nine of them, each is
 * one or two paths, and a library would ship hundreds of glyphs plus its own
 * sizing and stroke conventions to override. The five that appear in
 * mockups/v1d-apple.html are copied from it verbatim.
 *
 * None of these set a size or a colour. The consuming CSS does — `.item svg`,
 * `.ring svg`, `.act.ghost svg` — exactly as in the prototype, so an icon cannot
 * disagree with the row it sits in.
 */

function Svg({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true" focusable="false">
      {children}
    </svg>
  );
}

/** 我的一天. A sun: the day's working set. */
export function IconToday() {
  return (
    <Svg>
      <circle cx="12" cy="12" r="4.2" />
      <path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9L17 7M7 17l-2.1 2.1" />
    </Svg>
  );
}

/** 需要你. A clock: something has been waiting on you. */
export function IconNeeds() {
  return (
    <Svg>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7.5V12l3 2.5" />
    </Svg>
  );
}

/** 已完成. */
export function IconDone() {
  return (
    <Svg>
      <path d="M4.5 12.5l5 5 10-11" />
    </Svg>
  );
}

export function IconPlus() {
  return (
    <Svg>
      <path d="M12 5v14M5 12h14" />
    </Svg>
  );
}

/** The tick inside a completed task's ring. */
export function IconCheck() {
  return (
    <Svg>
      <path d="M5 13l4.5 4.5L19 7" />
    </Svg>
  );
}

export function IconSend() {
  return (
    <Svg>
      <path d="M12 19V5M6 11l6-6 6 6" />
    </Svg>
  );
}

/** Overflow affordance on a list row. Three dots, drawn as a stroked path. */
export function IconMore() {
  return (
    <Svg>
      <path d="M12 5.5v.01M12 12v.01M12 18.5v.01" strokeLinecap="round" />
    </Svg>
  );
}

/** Delete. An × rather than a bin: it is the row's quietest action. */
export function IconX() {
  return (
    <Svg>
      <path d="M6 6l12 12M18 6L6 18" strokeLinecap="round" />
    </Svg>
  );
}

/** Disclosure caret for the collapsed 已完成 group. Rotated by CSS. */
export function IconCaret({ className }: { className?: string }) {
  return (
    <Svg className={className}>
      <path d="M9 5l7 7-7 7" strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}

export function IconGear() {
  return (
    <Svg>
      <circle cx="12" cy="12" r="3.1" />
      <path d="M12 2.8v2.4M12 18.8v2.4M4.5 7.5l2.1 1.2M17.4 15.3l2.1 1.2M4.5 16.5l2.1-1.2M17.4 8.7l2.1-1.2" />
    </Svg>
  );
}

/** Back to the task list, from a secondary page. */
export function IconBack() {
  return (
    <Svg>
      <path d="M14 6l-6 6 6 6" strokeLinecap="round" strokeLinejoin="round" />
    </Svg>
  );
}
