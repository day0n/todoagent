"use client";

import { useEffect, useId, useState } from "react";

type NavLink = {
  href: string;
  label: string;
  external?: boolean;
};

export function SiteNav({
  downloadUrl,
  links,
}: {
  downloadUrl: string;
  links: NavLink[];
}) {
  const [open, setOpen] = useState(false);
  const menuId = useId();

  useEffect(() => {
    if (!open) return;

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };

    document.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";

    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [open]);

  return (
    <nav className={open ? "site-nav is-open" : "site-nav"} aria-label="主导航">
      <div className="nav-bar">
        <a className="brand" href="#top" aria-label="TodoAgent 首页" onClick={() => setOpen(false)}>
          <img src="/todoagent-icon.png" alt="" width={28} height={28} />
          <span>TodoAgent</span>
        </a>

        <div className="nav-links">
          {links.map((link) => (
            <a
              key={link.href}
              href={link.href}
              target={link.external ? "_blank" : undefined}
              rel={link.external ? "noreferrer" : undefined}
            >
              {link.label}
            </a>
          ))}
        </div>

        <div className="nav-end">
          <button
            type="button"
            className="nav-toggle"
            aria-expanded={open}
            aria-controls={menuId}
            aria-label={open ? "关闭菜单" : "打开菜单"}
            onClick={() => setOpen((value) => !value)}
          >
            <i />
          </button>
          <a className="nav-cta" href={downloadUrl} target="_blank" rel="noreferrer">
            下载
          </a>
        </div>
      </div>

      <div className="nav-panel" id={menuId} hidden={!open}>
        {links.map((link) => (
          <a
            key={link.href}
            href={link.href}
            target={link.external ? "_blank" : undefined}
            rel={link.external ? "noreferrer" : undefined}
            onClick={() => setOpen(false)}
          >
            {link.label}
          </a>
        ))}
      </div>

      {open ? (
        <button
          type="button"
          className="nav-backdrop"
          aria-label="关闭菜单"
          onClick={() => setOpen(false)}
        />
      ) : null}
    </nav>
  );
}
