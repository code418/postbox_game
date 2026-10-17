// Royal cypher display metadata, in reign order. The number keys 1–9 pick
// these in this order (0 is plain). Points come from the server session
// (Remote Config aware); labels mirror lib/monarch_info.dart.

export interface CypherInfo {
  key: string;
  /** What's cast on the box. */
  mono: string;
  name: string;
  years: string;
}

export const CYPHERS: ReadonlyArray<CypherInfo> = [
  { key: "VR", mono: "VR", name: "Victoria", years: "1837–1901" },
  { key: "EVIIR", mono: "EVIIR", name: "Edward VII", years: "1901–1910" },
  { key: "GVR", mono: "GVR", name: "George V", years: "1910–1936" },
  { key: "EVIIIR", mono: "EVIIIR", name: "Edward VIII", years: "1936" },
  { key: "GVIR", mono: "GVIR", name: "George VI", years: "1936–1952" },
  { key: "GR", mono: "GR", name: "George (generic)", years: "1910–1952" },
  { key: "EIIR", mono: "EIIR", name: "Elizabeth II", years: "1952–2022" },
  { key: "CIIIR", mono: "CIIIR", name: "Charles III", years: "2022–" },
  { key: "SCOTTISH_CROWN", mono: "Crown", name: "Scottish Crown", years: "Scotland, 1952–" },
];

export function cypherName(key: string | null | undefined): string {
  if (key === null || key === undefined || key === "") return "Plain";
  return CYPHERS.find((c) => c.key === key)?.name ?? key;
}

/** The cypher bound to a number key (1-based), or undefined. */
export function cypherForDigit(digit: number): CypherInfo | undefined {
  return digit >= 1 && digit <= CYPHERS.length ? CYPHERS[digit - 1] : undefined;
}
