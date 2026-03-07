declare module "ngeohash" {
  export function encode(latitude: number, longitude: number, precision?: number): string;
  export function neighbors(geohash: string): string[];
}
