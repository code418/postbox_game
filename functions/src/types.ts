/** Firestore postbox document (with optional fields we attach at query time). */
export interface PostboxDoc {
  geohash?: string;
  geopoint?: { _latitude?: number; _longitude?: number; latitude?: number; longitude?: number };
  monarch?: string;
  overpass_id?: number;
  reference?: string;
  /** UK county / unitary authority name, set by import_postboxes.js. */
  county?: string;
  /** "osm" (imported) or "user_report" (added from an accepted missing-postbox report). */
  source?: string;
  /** reports/{id} this postbox was created from (source === "user_report"). */
  reportId?: string;
  /** Admin uid that applied the last accepted cypher correction. */
  correctedBy?: string;
  correctedAt?: unknown;
  /** True when import_postboxes.js --prune marked this OSM node as no longer
   *  present in the upstream Overpass extract. Soft-marker only; cleared by any
   *  subsequent normal write to the doc. Runtime lookups skip these so users
   *  can't claim a postbox the OSM data says has gone. */
  removedFromOsm?: boolean;
  removedFromOsmAt?: unknown;
  distance?: number;
  compass?: { exact?: string };
  dailyClaim?: { date: string; by: string };
  claimedToday?: boolean;  // attached at query time by lookupPostboxes
  [key: string]: unknown;
}

/** Result of lookupPostboxes: postboxes by id, counts, points, compass sectors. */
export interface LookupResult {
  postboxes: Record<string, PostboxDoc>;
  counts: { total: number; claimedToday: number; [monarch: string]: number };
  points: { max: number; min: number };
  compass: Record<string, number>;
}

/** A photo attached to a problem report (stored under report_photos/{uid}/). */
export interface ReportPhoto {
  storagePath: string;
  /** GPS extracted from the photo's EXIF on the client, when present. */
  exifLat?: number;
  exifLng?: number;
  /** ISO timestamp from the photo's EXIF DateTimeOriginal, when present. */
  takenAt?: string;
}

/** A user-submitted report about a problem with postbox data (reports/{id}). */
export interface ReportDoc {
  type: "missing_postbox" | "wrong_cypher";
  status: "pending" | "accepted" | "rejected";
  reporterUid: string;
  createdAt?: unknown;
  note?: string;
  photos: ReportPhoto[];
  // missing_postbox:
  lat?: number;
  lng?: number;
  accuracyMeters?: number;
  // wrong_cypher:
  postboxId?: string;
  overpassId?: number;
  currentMonarch?: string | null;
  // suggested correction (both types):
  suggestedMonarch?: string | null;
  suggestedReference?: string;
  // review:
  reviewedBy?: string;
  reviewedAt?: unknown;
  reviewNote?: string;
  appliedToFirestore?: boolean;
  osmStatus?: "not_started" | "changeset_generated" | "changeset_failed";
  osmChangesetPath?: string;
  osmEditUrl?: string;
}
