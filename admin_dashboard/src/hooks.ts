// Data hooks: a keyed promise cache (so revisiting a report is instant and
// the next report can be prefetched), and token-authenticated photo URLs.

import { useCallback, useEffect, useState } from "react";
import { fetchBlob } from "./api.ts";

const cache = new Map<string, Promise<unknown>>();

export function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  let p = cache.get(key) as Promise<T> | undefined;
  if (!p) {
    p = load();
    cache.set(key, p);
    // Don't keep failures around: the next visit retries.
    p.catch(() => cache.delete(key));
  }
  return p;
}

export function invalidate(prefix: string): void {
  for (const k of cache.keys()) if (k.startsWith(prefix)) cache.delete(k);
}

export interface Resource<T> {
  data: T | undefined;
  error: Error | undefined;
  loading: boolean;
  reload: () => void;
}

/** Loads `key` through the cache; a null key means "nothing to load". */
export function useResource<T>(key: string | null, load: () => Promise<T>): Resource<T> {
  const [state, setState] = useState<{ key: string | null; data?: T; error?: Error }>({ key: null });
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (key === null) return;
    let live = true;
    cached(key, load).then(
      (data) => live && setState({ key, data }),
      (error: Error) => live && setState({ key, error }),
    );
    return () => {
      live = false;
    };
    // `load` is keyed by `key`: re-running on its identity would refetch every render.
  }, [key, nonce]);

  const reload = useCallback(() => {
    if (key !== null) cache.delete(key);
    setNonce((n) => n + 1);
  }, [key]);

  const current = state.key === key;
  return {
    data: current ? state.data : undefined,
    error: current ? state.error : undefined,
    loading: key !== null && (!current || (state.data === undefined && state.error === undefined)),
    reload,
  };
}

// ── photos ──────────────────────────────────────────────────────────────────
// <img> can't send the token header, so photos are fetched and shown from
// blob: URLs. A small LRU bounds memory; evicted URLs are revoked.

const PHOTO_LRU = 36;
const photoUrls = new Map<string, Promise<string>>();

function photoUrl(path: string): Promise<string> {
  const hit = photoUrls.get(path);
  if (hit) {
    photoUrls.delete(path);
    photoUrls.set(path, hit);
    return hit;
  }
  const p = fetchBlob(path).then((b) => URL.createObjectURL(b));
  p.catch(() => photoUrls.delete(path));
  photoUrls.set(path, p);
  while (photoUrls.size > PHOTO_LRU) {
    const [oldest, old] = photoUrls.entries().next().value as [string, Promise<string>];
    photoUrls.delete(oldest);
    old.then((u) => URL.revokeObjectURL(u), () => undefined);
  }
  return p;
}

export function usePhoto(path: string | null): { url?: string; error?: string } {
  const [state, setState] = useState<{ path: string | null; url?: string; error?: string }>({ path: null });
  useEffect(() => {
    if (path === null) return;
    let live = true;
    photoUrl(path).then(
      (url) => live && setState({ path, url }),
      (e: Error) => live && setState({ path, error: e.message }),
    );
    return () => {
      live = false;
    };
  }, [path]);
  return state.path === path ? { url: state.url, error: state.error } : {};
}
