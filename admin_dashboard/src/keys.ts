// Keyboard map for the review queue. Pure: (key event, decision mode,
// whether "g" was just pressed) → command. The App wires commands to actions.

export type DecisionMode = "idle" | "accept" | "reject";
export type View = "queue" | "history" | "osm";

export type Command =
  | { type: "next" }
  | { type: "prev" }
  | { type: "stageAccept" }
  | { type: "stageReject" }
  /** 1–9 = a cypher in reign order, 0 = plain. Stages an accept from idle. */
  | { type: "cypher"; digit: number }
  /** 0-based reject preset. */
  | { type: "preset"; index: number }
  | { type: "confirm"; override: boolean }
  | { type: "cancel" }
  | { type: "toggleBatch" }
  | { type: "batchReject" }
  | { type: "focusNote" }
  | { type: "focusReference" }
  | { type: "photos" }
  | { type: "osmLayer" }
  /** Switch the centre pane between the map and Street View. */
  | { type: "streetView" }
  | { type: "openEditor" }
  | { type: "goPrefix" }
  | { type: "view"; view: View }
  | { type: "help" };

export interface KeyInput {
  key: string;
  shiftKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  /** Focus is in a text input/textarea/select: only Esc and Enter count. */
  inTextField: boolean;
}

export function keyToCommand(e: KeyInput, mode: DecisionMode, goPending: boolean): Command | null {
  // Leave browser and OS shortcuts alone.
  if (e.ctrlKey || e.metaKey || e.altKey) return null;

  if (e.inTextField) {
    if (e.key === "Escape") return { type: "cancel" };
    if (e.key === "Enter" && mode !== "idle") return { type: "confirm", override: e.shiftKey };
    return null;
  }

  if (goPending) {
    if (e.key === "q") return { type: "view", view: "queue" };
    if (e.key === "h") return { type: "view", view: "history" };
    if (e.key === "o") return { type: "view", view: "osm" };
    return null;
  }

  switch (e.key) {
    case "j":
    case "ArrowDown":
      return { type: "next" };
    case "k":
    case "ArrowUp":
      return { type: "prev" };
    case "a":
      return { type: "stageAccept" };
    case "r":
      return { type: "stageReject" };
    case "R":
      return { type: "batchReject" };
    case "x":
      return { type: "toggleBatch" };
    case "n":
      return { type: "focusNote" };
    case "f":
      return { type: "focusReference" };
    case "p":
      return { type: "photos" };
    case "o":
      return { type: "osmLayer" };
    case "v":
      return { type: "streetView" };
    case "e":
      return { type: "openEditor" };
    case "g":
      return { type: "goPrefix" };
    case "?":
      return { type: "help" };
    case "Escape":
      return { type: "cancel" };
    case "Enter":
      return mode === "idle" ? null : { type: "confirm", override: e.shiftKey };
    default:
      break;
  }

  if (/^[0-9]$/.test(e.key)) {
    const digit = Number(e.key);
    if (mode === "reject") return digit >= 1 ? { type: "preset", index: digit - 1 } : null;
    return { type: "cypher", digit };
  }
  return null;
}

/** The shortcut sheet shown by "?", grouped. */
export const SHORTCUTS: ReadonlyArray<{ group: string; keys: ReadonlyArray<[string, string]> }> = [
  {
    group: "Move around",
    keys: [
      ["j or ↓", "Next report"],
      ["k or ↑", "Previous report"],
      ["p", "Open photos"],
      ["o", "Show live OSM post boxes on the map"],
      ["v", "Switch between the map and Street View"],
      ["e", "Open this spot in the iD editor"],
      ["g then q, h or o", "Queue, history or OSM edits"],
      ["?", "This list"],
    ],
  },
  {
    group: "Decide",
    keys: [
      ["a", "Start accepting"],
      ["1 to 9", "Accept with a cypher (reign order)"],
      ["0", "Accept as plain, no cypher"],
      ["r", "Start rejecting, then 1 to 9 picks a reason"],
      ["n / f", "Type a note / a reference"],
      ["Enter", "Confirm"],
      ["Shift+Enter", "Confirm despite a duplicate warning"],
      ["Esc", "Cancel"],
    ],
  },
  {
    group: "Batch",
    keys: [
      ["x", "Add to or remove from the batch"],
      ["Shift+R", "Reject the whole batch"],
    ],
  },
];
