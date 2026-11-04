import type { RefObject } from "react";
import type { ReportSummaryDto, SessionDto } from "../../../functions/src/_reviewTypes";
import { CypherPlates } from "./CypherPlates.tsx";
import { defaultCypher, unsureAllowed, type DecisionState } from "../decision.ts";
import { cypherName } from "../monarchs.ts";

interface Props {
  report: ReportSummaryDto;
  session: SessionDto;
  decision: DecisionState;
  onChange: (d: DecisionState) => void;
  onConfirm: (override: boolean) => void;
  /** Why confirming is blocked right now (shown once the user tries). */
  hint: string | null;
  busy: boolean;
  error: string | null;
  noteRef: RefObject<HTMLInputElement | null>;
  referenceRef: RefObject<HTMLInputElement | null>;
}

function acceptLabel(r: ReportSummaryDto, d: DecisionState): string {
  if (r.type === "missing_postbox") return "Add postbox";
  if (d.cypher.kind === "unsure") return "Change cypher";
  return `Change cypher to ${cypherName(d.cypher.kind === "key" ? d.cypher.key : null)}`;
}

export function DecisionPanel({ report, session, decision, onChange, onConfirm, hint, busy, error, noteRef, referenceRef }: Props) {
  const set = (patch: Partial<DecisionState>) => onChange({ ...decision, ...patch });
  const suggested = report.hasSuggestedMonarch ? defaultCypher(report) : null;
  const noteLen = decision.note.trim().length;

  return (
    <section className="panel panel-decision" aria-labelledby="decision-h">
      <h2 id="decision-h">Decision</h2>
      <div className="mode-toggle" role="group" aria-label="Accept or reject">
        <button type="button" className={`mode mode-accept${decision.mode === "accept" ? " is-on" : ""}`} aria-pressed={decision.mode === "accept"} onClick={() => set({ mode: "accept" })} disabled={busy}>
          Accept <kbd>a</kbd>
        </button>
        <button type="button" className={`mode mode-reject${decision.mode === "reject" ? " is-on" : ""}`} aria-pressed={decision.mode === "reject"} onClick={() => set({ mode: "reject" })} disabled={busy}>
          Reject <kbd>r</kbd>
        </button>
      </div>

      {decision.mode === "idle" && <p className="muted">Press a to accept or r to reject. Number keys pick a cypher straight away.</p>}

      {decision.mode === "accept" && (
        <>
          <CypherPlates
            value={decision.cypher}
            onChange={(cypher) => set({ cypher })}
            monarchs={session.monarchs}
            plainPoints={session.plainPoints}
            current={report.type === "wrong_cypher" ? report.currentMonarch : undefined}
            suggested={suggested}
            allowUnsure={unsureAllowed(report)}
            disabled={busy}
          />
          <label className="field">
            <span className="field-label">
              Reference <kbd>f</kbd>
              {report.suggestedReference && <span className="muted"> Reporter said {report.suggestedReference}</span>}
            </span>
            <input
              ref={referenceRef}
              value={decision.reference}
              maxLength={session.referenceMax}
              onChange={(e) => set({ reference: e.target.value })}
              placeholder={report.type === "wrong_cypher" ? "Leave empty to keep the current one" : "None"}
              disabled={busy}
            />
          </label>
        </>
      )}

      {decision.mode === "reject" && (
        <ol className="presets" aria-label="Reasons">
          {session.rejectPresets.map((p, i) => (
            <li key={p}>
              <button type="button" className={decision.note === p ? "is-on" : undefined} onClick={() => set({ note: p })} disabled={busy}>
                <kbd>{i + 1}</kbd>
                {p}
              </button>
            </li>
          ))}
        </ol>
      )}

      {decision.mode !== "idle" && (
        <>
          <label className="field">
            <span className="field-label">
              Note to the reporter <kbd>n</kbd>
              <span className={`counter${noteLen > session.noteMax ? " warn" : ""}`}>{noteLen} of {session.noteMax}</span>
            </span>
            <input
              ref={noteRef}
              value={decision.note}
              onChange={(e) => set({ note: e.target.value })}
              placeholder={decision.mode === "reject" ? "Shown in their My reports list" : "Optional, shown in their My reports list"}
              disabled={busy}
            />
          </label>
          <div className="confirm-row">
            <button type="button" className={decision.mode === "accept" ? "primary" : "danger"} onClick={() => onConfirm(false)} disabled={busy}>
              {busy ? "Saving" : decision.mode === "accept" ? acceptLabel(report, decision) : "Reject report"}
              {!busy && <kbd>Enter</kbd>}
            </button>
            <button type="button" className="quiet" onClick={() => set({ mode: "idle" })} disabled={busy}>
              Cancel <kbd>Esc</kbd>
            </button>
          </div>
          {hint && <p className="hint-line" role="status">{hint}</p>}
          {error && <p className="error-line" role="alert">{error}</p>}
        </>
      )}
    </section>
  );
}
