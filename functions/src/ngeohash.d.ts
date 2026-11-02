declare module "ngeohash" {
  export function encode(latitude: number, longitude: number, precision?: number): string;
  export function neighbors(geohash: string): string[];
  /** Every hash at [precision] whose cell intersects the bounding box. */
  export function bboxes(
    minLat: number, minLon: number, maxLat: number, maxLon: number, precision?: number,
  ): string[];
  /** [minLat, minLon, maxLat, maxLon] of a hash's cell. */
  export function decode_bbox(hash: string): [number, number, number, number];
}
