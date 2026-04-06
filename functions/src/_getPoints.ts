/**
 * Maps monarch cypher (royal_cypher from OSM) to points.
 * EIIR: 2, GR/GVR/GVIR: 4, VR: 7, EVIIR/CIIIR: 9, EVIIIR: 12.
 */
export function getPoints(monarch: string): number {
  switch (monarch) {
    case "GR":
    case "GVR":
    case "GVIR":
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
