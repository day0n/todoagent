"use client";

import { createPortal } from "react-dom";
import { useEffect, useLayoutEffect, useRef, useState } from "react";

export interface MenuOption<T extends string> {
  value: T;
  label: string;
  description?: string;
  disabled?: boolean;
}

/** Product-styled select menu; avoids the unthemeable operating-system popup. */
export function SelectMenu<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
  placeholder = "请选择",
  className = "",
  menuClassName = "",
}: {
  value: T | "";
  options: MenuOption<T>[];
  onChange: (value: T) => void;
  ariaLabel: string;
  placeholder?: string;
  className?: string;
  menuClassName?: string;
}) {
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState({ top: 0, left: 0, width: 220, above: false });
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const selected = options.find((option) => option.value === value);

  useLayoutEffect(() => {
    if (!open || triggerRef.current === null) return;
    const rect = triggerRef.current.getBoundingClientRect();
    const expectedHeight = Math.min(300, options.length * 52 + 12);
    const above = window.innerHeight - rect.bottom < expectedHeight && rect.top > expectedHeight;
    setPosition({
      top: above ? rect.top - 8 : rect.bottom + 8,
      left: Math.min(rect.left, window.innerWidth - Math.max(rect.width, 220) - 12),
      width: Math.max(rect.width, 220),
      above,
    });
  }, [open, options.length]);

  useEffect(() => {
    if (!open) return;
    queueMicrotask(() => {
      const selectedOption = menuRef.current?.querySelector<HTMLElement>('[role="option"][aria-selected="true"]');
      const firstOption = menuRef.current?.querySelector<HTMLElement>('[role="option"]:not([disabled])');
      (selectedOption ?? firstOption)?.focus();
    });
    const close = (event: MouseEvent): void => {
      const node = event.target as Node;
      if (!triggerRef.current?.contains(node) && !menuRef.current?.contains(node)) setOpen(false);
    };
    const key = (event: KeyboardEvent): void => {
      if (event.key === "Escape") {
        setOpen(false);
        triggerRef.current?.focus();
      }
    };
    const dismiss = (): void => setOpen(false);
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", dismiss);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", dismiss);
    };
  }, [open]);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        className={`product-select ${className}`.trim()}
        aria-label={ariaLabel}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((current) => !current)}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            setOpen(true);
          }
        }}
      >
        <span>{selected?.label ?? placeholder}</span>
        <i aria-hidden="true" />
      </button>
      {open && typeof document !== "undefined" ? createPortal(
        <div
          ref={menuRef}
          className={`product-select-menu${position.above ? " above" : ""}${menuClassName ? ` ${menuClassName}` : ""}`}
          role="listbox"
          aria-label={ariaLabel}
          style={{ top: position.top, left: position.left, width: position.width, transform: position.above ? "translateY(-100%)" : undefined }}
        >
          {options.map((option) => (
            <button
              key={option.value}
              type="button"
              role="option"
              aria-selected={option.value === value}
              disabled={option.disabled}
              onClick={() => {
                onChange(option.value);
                setOpen(false);
                triggerRef.current?.focus();
              }}
            >
              <span className="product-select-check" aria-hidden="true">{option.value === value ? "✓" : ""}</span>
              <span><strong>{option.label}</strong>{option.description ? <small>{option.description}</small> : null}</span>
            </button>
          ))}
        </div>,
        document.body,
      ) : null}
    </>
  );
}

/** A consistently styled destructive-action confirmation with focus return. */
export function ConfirmButton({
  children,
  className,
  ariaLabel,
  title,
  heading,
  description,
  confirmLabel,
  onConfirm,
}: {
  children: React.ReactNode;
  className?: string;
  ariaLabel?: string;
  title?: string;
  heading: string;
  description: string;
  confirmLabel: string;
  onConfirm: () => void;
}) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  return (
    <>
      <button ref={triggerRef} type="button" className={className} aria-label={ariaLabel} title={title} onClick={() => setOpen(true)}>{children}</button>
      {open ? (
        <ProductDialog
          heading={heading}
          description={description}
          confirmLabel={confirmLabel}
          destructive
          onCancel={() => { setOpen(false); queueMicrotask(() => triggerRef.current?.focus()); }}
          onConfirm={() => { setOpen(false); onConfirm(); }}
        />
      ) : null}
    </>
  );
}

export function PromptDialog({
  open,
  heading,
  description,
  placeholder,
  confirmLabel,
  onCancel,
  onConfirm,
}: {
  open: boolean;
  heading: string;
  description?: string;
  placeholder?: string;
  confirmLabel: string;
  onCancel: () => void;
  onConfirm: (value: string) => void;
}) {
  const [value, setValue] = useState("");
  useEffect(() => {
    if (!open) setValue("");
  }, [open]);
  if (!open) return null;
  return (
    <ProductDialog
      heading={heading}
      description={description}
      confirmLabel={confirmLabel}
      confirmDisabled={value.trim() === ""}
      onCancel={onCancel}
      onConfirm={() => onConfirm(value.trim())}
    >
      <input autoFocus className="product-dialog-input" value={value} placeholder={placeholder} onChange={(event) => setValue(event.target.value)} />
    </ProductDialog>
  );
}

function ProductDialog({
  heading,
  description,
  children,
  confirmLabel,
  confirmDisabled = false,
  destructive = false,
  onCancel,
  onConfirm,
}: {
  heading: string;
  description?: string;
  children?: React.ReactNode;
  confirmLabel: string;
  confirmDisabled?: boolean;
  destructive?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const first = dialogRef.current?.querySelector<HTMLElement>("input, button");
    first?.focus();
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") onCancel();
      if (event.key !== "Tab" || dialogRef.current === null) return;
      const items = [...dialogRef.current.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled])')];
      if (items.length === 0) return;
      const firstItem = items[0];
      const lastItem = items.at(-1);
      if (!firstItem || !lastItem) return;
      if (event.shiftKey && document.activeElement === firstItem) { event.preventDefault(); lastItem.focus(); }
      if (!event.shiftKey && document.activeElement === lastItem) { event.preventDefault(); firstItem.focus(); }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onCancel]);

  return createPortal(
    <div className="product-dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel(); }}>
      <div ref={dialogRef} className="product-dialog" role="dialog" aria-modal="true" aria-labelledby="product-dialog-title">
        <div className="product-dialog-mark" aria-hidden="true">{destructive ? "!" : "+"}</div>
        <div className="product-dialog-copy">
          <h2 id="product-dialog-title">{heading}</h2>
          {description ? <p>{description}</p> : null}
        </div>
        {children ? <div className="product-dialog-content">{children}</div> : null}
        <div className="product-dialog-actions">
          <button type="button" className="btn" onClick={onCancel}>取消</button>
          <button type="button" className={`btn${destructive ? " product-dialog-danger" : " btn-primary"}`} disabled={confirmDisabled} onClick={onConfirm}>{confirmLabel}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
