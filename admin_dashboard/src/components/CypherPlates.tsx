import type { MonarchOptionDto } from "../../../functions/src/_reviewTypes";
import { CYPHERS } from "../monarchs.ts";
import { sameChoice, type CypherChoice } from "../decision.ts";

interface Props {
  value: CypherChoice;
  onChange: (c: CypherChoice) => void;
  monarchs: ReadonlyArray<MonarchOptionDto>;
  plainPoints: number;
  /** The box's cypher as stored now, marked on its plate: null = plain,
   *  undefined = not applicable (a missing-postbox report). */
  current: string | null | undefined;
  /** The reporter's suggestion, marked on its plate. */
  suggested: CypherChoice | null;
  allowUnsure: boolean;
  disabled?: boolean;
}

/** The cypher picker, drawn like the cast lettering on a box door. Number keys
 *  1–9 follow the plates' reign order; 0 is plain. */
export function CypherPlates({ value, onChange, monarchs, plainPoints, current, suggested, allowUnsure, disabled }: Props) {
  const points = new Map(monarchs.map((m) => [m.key, m.points]));
  const plate = (choice: CypherChoice, mono: string, title: string, sub: string, keyHint: string | null, pts: number | null, isCurrent: boolean) => {
    const selected = sameChoice(choice, value);
    const isSuggested = suggested !== null && sameChoice(choice, suggested);
    return (
      <button
        type="button"
        key={choice.kind === "key" ? choice.key : choice.kind}
        className={`plate${selected ? " is-selected" : ""}${choice.kind !== "key" ? " plate-plain" : ""}`}
        aria-pressed={selected}
        disabled={disabled}
        onClick={() => onChange(choice)}
        title={`${title}${sub ? ` (${sub})` : ""}`}
      >
        {keyHint !== null && <kbd className="plate-key">{keyHint}</kbd>}
        <span className={`plate-mono${mono.length > 4 ? " is-long" : ""}`}>{mono}</span>
        <span className="plate-name">{title}</span>
        <span className="plate-meta">
          {pts !== null && <span className="plate-pts">{pts} pts</span>}
          {isCurrent && <span className="plate-tag">now</span>}
          {isSuggested && <span className="plate-tag plate-tag-suggested">suggested</span>}
        </span>
      </button>
    );
  };

  return (
    <div className="plates" role="group" aria-label="Royal cypher">
      {CYPHERS.map((c, i) =>
        plate({ kind: "key", key: c.key }, c.mono, c.name, c.years, String(i + 1), points.get(c.key) ?? null, current === c.key),
      )}
      {plate({ kind: "plain" }, "—", "Plain", "no cypher", "0", plainPoints, current === null)}
      {allowUnsure && plate({ kind: "unsure" }, "?", "Not sure", "leave unset", null, null, false)}
    </div>
  );
}
