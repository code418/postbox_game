import { useEffect, useRef, useState } from "react";
import type { SessionDto } from "../../../functions/src/_reviewTypes";
import { SHORTCUTS, type View } from "../keys.ts";

export function TopBar({ session, view, onView, pendingCount, onHelp }: {
  session: SessionDto;
  view: View;
  onView: (v: View) => void;
  pendingCount: number | null;
  onHelp: () => void;
}) {
  const tabs: Array<[View, string, string]> = [
    ["queue", "Queue", pendingCount === null ? "" : String(pendingCount)],
    ["history", "History", ""],
    ["osm", "OSM edits", ""],
  ];
  return (
    <header className="topbar">
      <span className="brand">
        <span className="pillar" aria-hidden="true" />
        Postbox review
      </span>
      <nav className="tabs" aria-label="Views">
        {tabs.map(([v, label, count]) => (
          <button key={v} type="button" className={view === v ? "is-on" : undefined} aria-current={view === v ? "page" : undefined} onClick={() => onView(v)}>
            {label}
            {count && <span className="count">{count}</span>}
          </button>
        ))}
      </nav>
      <span className="status">
        {session.maintenanceMode && (
          <span className={`badge ${session.ignoreMaintenance ? "badge-gold" : "badge-red"}`}>
            {session.ignoreMaintenance ? "Maintenance mode on, reviews allowed" : "Maintenance mode on, reviews paused"}
          </span>
        )}
        {session.pointsOverrideActive && <span className="badge">Remote Config points</span>}
        <span className="reviewer" title={session.reviewer.uid}>
          {session.reviewer.displayName ?? session.reviewer.uid} on {session.projectId}
        </span>
        <button type="button" className="help-button" onClick={onHelp} aria-label="Keyboard shortcuts">?</button>
      </span>
    </header>
  );
}

/** Opens a <dialog> modally on mount; closing it fires its onClose. */
function useModal() {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  return ref;
}

export function HelpDialog({ onClose }: { onClose: () => void }) {
  const ref = useModal();
  return (
    <dialog ref={ref} className="sheet" onClose={onClose} aria-labelledby="help-h">
      <h2 id="help-h">Keyboard shortcuts</h2>
      <div className="shortcut-groups">
        {SHORTCUTS.map((g) => (
          <section key={g.group}>
            <h3>{g.group}</h3>
            <dl className="shortcuts">
              {g.keys.map(([k, what]) => (
                <div key={k}>
                  <dt><kbd>{k}</kbd></dt>
                  <dd>{what}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>
      <form method="dialog">
        <button type="submit" className="quiet">Close</button>
      </form>
    </dialog>
  );
}

export function BatchRejectDialog({ count, presets, noteMax, onConfirm, onClose }: {
  count: number;
  presets: ReadonlyArray<string>;
  noteMax: number;
  onConfirm: (note: string) => Promise<void>;
  onClose: () => void;
}) {
  const ref = useModal();
  const [note, setNote] = useState(presets[0] ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const tooLong = note.trim().length > noteMax;
  const submit = () => {
    setBusy(true);
    setError(null);
    onConfirm(note.trim()).then(
      () => ref.current?.close(),
      (e: Error) => {
        setBusy(false);
        setError(e.message);
      },
    );
  };
  return (
    <dialog ref={ref} className="sheet" onClose={onClose} aria-labelledby="batch-h">
      <h2 id="batch-h">Reject {count} report{count === 1 ? "" : "s"}</h2>
      <p>Every reporter sees the same note in their My reports list.</p>
      <ol className="presets">
        {presets.map((p) => (
          <li key={p}>
            <button type="button" className={note === p ? "is-on" : undefined} onClick={() => setNote(p)} disabled={busy}>{p}</button>
          </li>
        ))}
      </ol>
      <label className="field">
        <span className="field-label">
          Note to the reporters
          <span className={`counter${tooLong ? " warn" : ""}`}>{note.trim().length} of {noteMax}</span>
        </span>
        <input value={note} onChange={(e) => setNote(e.target.value)} disabled={busy} autoFocus />
      </label>
      {error && <p className="error-line" role="alert">{error}</p>}
      <div className="confirm-row">
        <button type="button" className="danger" onClick={submit} disabled={busy || tooLong}>
          {busy ? "Rejecting" : `Reject ${count} report${count === 1 ? "" : "s"}`}
        </button>
        <button type="button" className="quiet" onClick={() => ref.current?.close()} disabled={busy}>Cancel</button>
      </div>
    </dialog>
  );
}

export interface Toast {
  id: number;
  text: string;
  tone: "ok" | "error";
  links?: Array<{ label: string; href?: string; onClick?: () => void }>;
}

export function Toasts({ toasts, onDismiss }: { toasts: ReadonlyArray<Toast>; onDismiss: (id: number) => void }) {
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast toast-${t.tone}`}>
          <span>{t.text}</span>
          {t.links?.map((l) =>
            l.href ? (
              <a key={l.label} href={l.href} target="_blank" rel="noopener noreferrer">{l.label}</a>
            ) : (
              <button key={l.label} type="button" className="link" onClick={l.onClick}>{l.label}</button>
            ),
          )}
          <button type="button" className="toast-x" onClick={() => onDismiss(t.id)} aria-label="Dismiss">×</button>
        </div>
      ))}
    </div>
  );
}
