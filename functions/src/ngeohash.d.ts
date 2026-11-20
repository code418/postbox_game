declare module "ngeohash" {
  export function encode(latitude: number, longitude: number, precision?: number): string;
  export function neighbors(geohash: string): string[];
  /** Centre of the geohash cell, with the half-extent of the cell as `error`. */
  export function decode(geohash: string): {
    latitude: number;
    longitude: number;
    error: { latitude: number; longitude: number };
  };
  /** [minLat, minLon, maxLat, maxLon] of the geohash cell. */
  export function decode_bbox(geohash: string): [number, number, number, number];
}
