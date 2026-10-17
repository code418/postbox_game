// In-memory mirror of the `reports` collection for the local review
// dashboard: one Admin SDK listener, so the queue, history, reporter history,
// nearby reports and the pending-OSM list are all answered from memory (no
// composite indexes, and j/k through the queue costs no Firestore round trip).
// Writes never go through this cache: performReview re-reads the doc first.

import type { firestore } from "firebase-admin";
import type { StoredReport } from "../../_reportContext";
import { getLatLng } from "../../_geo";
import type { PostboxDoc } from "../../types";

type LatLng = { lat: number; lng: number };

const NAME_TTL_MS = 10 * 60 * 1000;
const GET_ALL_CHUNK = 100;
const RESUBSCRIBE_MS = 5_000;

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export class ReportsStore {
  private readonly docs = new Map<string, StoredReport>();
  /** postboxId → position, filled lazily (wrong_cypher reports carry no coordinates). */
  readonly boxPositions = new Map<string, LatLng>();
  private readonly names = new Map<string, { name: string | null; at: number }>();
  private unsubscribe: (() => void) | null = null;
  private stopped = false;
  ready = false;

  constructor(private readonly db: firestore.Firestore) {}

  /** Subscribes and resolves once the first snapshot has landed. */
  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      let first = true;
      const subscribe = () => {
        let initial = true;
        this.unsubscribe = this.db.collection("reports").onSnapshot(
          (snap) => {
            if (initial) {
              // A (re)subscription's first snapshot is the whole collection:
              // rebuild, so docs deleted while we were disconnected go too.
              initial = false;
              this.docs.clear();
              for (const doc of snap.docs) this.docs.set(doc.id, { id: doc.id, data: doc.data() as StoredReport["data"] });
            } else {
              for (const ch of snap.docChanges()) {
                if (ch.type === "removed") this.docs.delete(ch.doc.id);
                else this.docs.set(ch.doc.id, { id: ch.doc.id, data: ch.doc.data() as StoredReport["data"] });
              }
            }
            this.ready = true;
            if (first) {
              first = false;
              resolve();
            }
          },
          (err) => {
            console.error("[review-dashboard] reports listener failed:", err.message);
            if (first) {
              first = false;
              reject(err);
              return;
            }
            // A listener error is terminal for that listener: resubscribe.
            this.ready = false;
            if (!this.stopped) setTimeout(subscribe, RESUBSCRIBE_MS);
          },
        );
      };
      subscribe();
    });
  }

  stop(): void {
    this.stopped = true;
    this.unsubscribe?.();
  }

  all(): StoredReport[] {
    return [...this.docs.values()];
  }

  get(id: string): StoredReport | undefined {
    return this.docs.get(id);
  }

  /** Re-reads one report straight away (after a write), rather than waiting
   *  for the listener to deliver it. */
  async refresh(id: string): Promise<StoredReport | undefined> {
    const snap = await this.db.collection("reports").doc(id).get();
    if (snap.exists) this.docs.set(id, { id, data: snap.data() as StoredReport["data"] });
    else this.docs.delete(id);
    return this.docs.get(id);
  }

  /** Display names (users/{uid}.displayName), cached for 10 minutes. */
  async resolveNames(uids: Iterable<string>, now: number = Date.now()): Promise<Map<string, string | null>> {
    const wanted = [...new Set(uids)].filter((u) => u.length > 0 && !u.includes("/"));
    const stale = wanted.filter((u) => {
      const hit = this.names.get(u);
      return !hit || now - hit.at > NAME_TTL_MS;
    });
    const refs = stale.map((u) => this.db.collection("users").doc(u));
    const snaps = (await Promise.all(chunk(refs, GET_ALL_CHUNK).map((c) => this.db.getAll(...c)))).flat();
    for (const s of snaps) {
      const name = s.exists ? (s.data() as { displayName?: unknown }).displayName : undefined;
      this.names.set(s.id, { name: typeof name === "string" ? name : null, at: now });
    }
    return new Map(wanted.map((u) => [u, this.names.get(u)?.name ?? null]));
  }

  /** Fills boxPositions for any of these postbox ids not yet known. */
  async resolveBoxPositions(postboxIds: Iterable<string>): Promise<void> {
    const missing = [...new Set(postboxIds)].filter((id) => id.length > 0 && !id.includes("/") && !this.boxPositions.has(id));
    const refs = missing.map((id) => this.db.collection("postbox").doc(id));
    const snaps = (await Promise.all(chunk(refs, GET_ALL_CHUNK).map((c) => this.db.getAll(...c)))).flat();
    for (const s of snaps) {
      const pos = s.exists ? getLatLng((s.data() as PostboxDoc).geopoint) : null;
      if (pos) this.boxPositions.set(s.id, pos);
    }
  }
}
