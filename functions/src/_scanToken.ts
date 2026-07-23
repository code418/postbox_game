// Server-issued offline capture token (ROADMAP v1.5, offline play Phases 2-3).
//
// The travel-speed check was never really an anti-spoof control (the server
// has always trusted client lat/lng) — what it actually is, is a
// SERIALISATION TAX: farming boxes forces a script to space its calls out in
// real wall-clock time. A naive offline claim deletes that tax: with
// deterministic claim IDs an attacker could save an outbox, shift every
// capture time by +24h and resubmit the same walk daily from an armchair —
// the implied speeds of a uniformly-shifted trace are identical.
//
// The fix: `nearbyPostboxes` signs a token binding {uid, scan position,
// issuedAtMs, nonce}. Every offline capture carries it, and the flush
// enforces capturedAtMs >= token.issuedAtMs and capturedAtMs <= serverNow.
// Both bounds are server-attested, so the offline timeline must fit inside a
// wall-clock window the server actually observed — restoring the tax.
//
// The scanId IS the token: the server has already told this user a box is
// near that position, so the marginal abuse surface is small.
//
// Secret: Cloud Secret Manager via defineSecret("OFFLINE_SCAN_SECRET") on the
// issuing/verifying callables; at runtime the platform exposes it as
// process.env.OFFLINE_SCAN_SECRET (read by getScanSecret so unit tests can
// inject). Fail-open on ISSUE (scan works, offline capture unavailable),
// fail-closed on VERIFY.

import { createHmac, timingSafeEqual } from "crypto";

/** Env var name the platform binds the Secret Manager secret to. */
export const SCAN_SECRET_ENV = "OFFLINE_SCAN_SECRET";

export interface ScanTokenPayload {
  uid: string;
  /** The scanned position the token is bound to. */
  lat: number;
  lng: number;
  issuedAtMs: number;
  nonce: string;
}

/** The runtime secret, or undefined when not configured (e.g. emulator). */
export function getScanSecret(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  const s = env[SCAN_SECRET_ENV];
  return typeof s === "string" && s.length > 0 ? s : undefined;
}

function hmac(body: string, secret: string): Buffer {
  return createHmac("sha256", secret).update(body).digest();
}

/** Sign a scan token: base64url(payload JSON) + "." + base64url(HMAC-SHA256). */
export function signScanToken(payload: ScanTokenPayload, secret: string): string {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const mac = hmac(body, secret).toString("base64url");
  return `${body}.${mac}`;
}

/**
 * Verify a token string: signature (timing-safe), well-formed payload, and —
 * when [uid] is given — that the token belongs to that user. Returns the
 * payload, or null on ANY failure (never throws on malformed input).
 */
export function verifyScanToken(
  token: string,
  uid: string | undefined,
  secret: string,
): ScanTokenPayload | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 2) return null;
    const [body, mac] = parts;
    const expected = hmac(body, secret);
    const given = Buffer.from(mac, "base64url");
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
      return null;
    }
    const parsed = JSON.parse(Buffer.from(body, "base64url").toString()) as ScanTokenPayload;
    if (
      typeof parsed !== "object" || parsed === null ||
      typeof parsed.uid !== "string" ||
      typeof parsed.lat !== "number" || !Number.isFinite(parsed.lat) ||
      typeof parsed.lng !== "number" || !Number.isFinite(parsed.lng) ||
      typeof parsed.issuedAtMs !== "number" || !Number.isFinite(parsed.issuedAtMs) ||
      typeof parsed.nonce !== "string"
    ) {
      return null;
    }
    if (uid !== undefined && parsed.uid !== uid) return null;
    return { uid: parsed.uid, lat: parsed.lat, lng: parsed.lng, issuedAtMs: parsed.issuedAtMs, nonce: parsed.nonce };
  } catch {
    return null;
  }
}
