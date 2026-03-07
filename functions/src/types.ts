/** Firestore postbox document (with optional fields we attach at query time). */
export interface PostboxDoc {
  position?: {
    geohash?: string;
    geopoint?: { _latitude?: number; _longitude?: number; latitude?: number; longitude?: number };
  };
  monarch?: string;
  distance?: number;
  compass?: { exact?: string };
  [key: string]: unknown;
}

/** Result of lookupPostboxes: postboxes by id, counts, points, compass sectors. */
export interface LookupResult {
  postboxes: Record<string, PostboxDoc>;
  counts: { total: number; [monarch: string]: number };
  points: { max: number; min: number };
  compass: Record<string, number>;
}
