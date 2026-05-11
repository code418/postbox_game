/**
 * Maps monarch cypher (royal_cypher from OSM) to points.
 * EIIR: 2, GR/GVR/GVIR/SCOTTISH_CROWN: 4, VR: 7, EVIIR/CIIIR: 9, EVIIIR: 12.
 */
export function getPoints(monarch: string): number {
  switch (monarch) {
    case "GR":
    case "GVR":
    case "GVIR":
    case "SCOTTISH_CROWN":
      return 4;
    case "VR":
      return 7;
    case "EVIIR":
    case "CIIIR":
      return 9;
    case "EVIIIR":
      return 12;
    default:
      return 2;
  }
}

/**
 * The set of recognised cypher keys. A postbox with any other (or no) cypher
 * scores the default 2 points. Kept in sync with MonarchInfo.labels on the
 * Flutter side and the values import_postboxes.js will store.
 */
export const KNOWN_MONARCHS: ReadonlyArray<string> = [
  "EIIR", "GR", "GVR", "GVIR", "SCOTTISH_CROWN", "VR", "EVIIR", "CIIIR", "EVIIIR",
];

/** Points for a (possibly null/undefined) monarch — null/plain → default 2. */
export function pointsForMonarch(monarch: string | null | undefined): number {
  return typeof monarch === "string" && monarch.length > 0 ? getPoints(monarch) : 2;
}
