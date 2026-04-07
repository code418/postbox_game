/** Firestore postbox document (with optional fields we attach at query time). */
export interface PostboxDoc {
  geohash?: string;
  geopoint?: { _latitude?: number; _longitude?: number; latitude?: number; longitude?: number };
  monarch?: string;
  overpass_id?: number;
  reference?: string;
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
