import { useEffect, useMemo, useState } from "react";
import type { OsmBatchDto, OsmBatchEntryDto, ReportSummaryDto } from "../../../functions/src/_reviewTypes";
import { api, saveFile } from "../api.ts";
import { cypherName } from "../monarchs.ts";
import { coords, idEditorUrl, relativeTime } from "../format.ts";

const STATUS_TEXT: Record<OsmBatchEntryDto["status"], string> = {
  included: "In the file",
  merged_into_create: "Folded into its new box",
  already_applied: "OSM already has it",
  already_on_osm: "OSM already has a box here",
  node_missing: "Node deleted on OSM",
  fetch_failed: "OSM didn't answer",
  conflict: "Conflicting reports",
  no_target: "Nothing to edit yet",
};

const SKIP_REASON: Partial<Record<OsmBatchEntryDto["status"], string>> = {
  already_applied: "OSM already had these tags",
  already_on_osm: "OSM already has a post box here",
  node_missing: "The node was deleted on OSM",
};

export function OsmView({ notify }: { notify: (msg: string) => void }) {
  const [rows, setRows] = useState<ReportSummaryDto[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [batch, setBatch] = useState<OsmBatchDto | null>(null);
  const [busy, setBusy] = useState(false);
  const [changeset, setChangeset] = useState("");
  const [nodeIds, setNodeIds] = useState<Record<string, string>>({});
  const [skipReason, setSkipReason] = useState("");

  const load = () =>
    api.osmPending().then(
      (r) => {
        setRows(r.reports);
        setSelected(new Set(r.reports.map((x) => x.id)));
        setError(null);
      },
      (e: Error) => setError(e.message),
    );
  useEffect(() => {
    void load();
  }, []);

  const byId = useMemo(() => new Map((rows ?? []).map((r) => [r.id, r])), [rows]);
  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const build = () =>
    run(async () => {
      setBatch(await api.osmBatch([...selected]));
      setNodeIds({});
      setChangeset("");
    });

  const doneEntries = batch?.entries.filter((e) => SKIP_REASON[e.status] !== undefined) ?? [];
  const markAllDone = () =>
    run(async () => {
      const byReason = new Map<string, string[]>();
      for (const e of doneEntries) {
        const reason = SKIP_REASON[e.status] as string;
        byReason.set(reason, [...(byReason.get(reason) ?? []), e.reportId]);
      }
      await Promise.all([...byReason].map(([reason, ids]) => api.markSkipped(ids, reason)));
      const ids = doneEntries.map((e) => e.reportId);
      notify(`Marked ${ids.length} report${ids.length === 1 ? "" : "s"} as needing no upload.`);
      setBatch((b) => (b ? { ...b, entries: b.entries.filter((e) => !ids.includes(e.reportId)) } : b));
      await load();
    });

  const uploadedIds = batch?.entries.filter((e) => e.status === "included" || e.status === "merged_into_create").map((e) => e.reportId) ?? [];
  const createEntries = batch?.entries.filter((e) => e.action === "create" && e.status === "included") ?? [];

  const recordUpload = () =>
    run(async () => {
      const cs = changeset.trim() === "" ? null : Number(changeset);
      if (cs !== null && (!Number.isInteger(cs) || cs <= 0)) throw new Error("The changeset id is a whole number, like 154012345.");
      const created: Record<string, number> = {};
      for (const [rid, v] of Object.entries(nodeIds)) {
        if (v.trim() === "") continue;
        const n = Number(v);
        if (!Number.isInteger(n) || n <= 0) throw new Error(`The node id for ${rid} is a whole number.`);
        created[rid] = n;
      }
      await api.markUploaded(uploadedIds, cs, created);
      notify(`Recorded ${uploadedIds.length} report${uploadedIds.length === 1 ? "" : "s"} as uploaded to OSM.`);
      setBatch(null);
      await load();
    });

  const skip = (ids: string[], reason: string) =>
    run(async () => {
      await api.markSkipped(ids, reason);
      notify(`Marked ${ids.length} report${ids.length === 1 ? "" : "s"} as needing no upload.`);
      setBatch((b) => (b ? { ...b, entries: b.entries.filter((e) => !ids.includes(e.reportId)) } : b));
      await load();
    });

  const toggle = (id: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  return (
    <main className="pane pane-wide" aria-labelledby="osm-h">
      <h1 id="osm-h">OSM edits</h1>
      <p className="lede">
        Accepted reports whose change isn't on OpenStreetMap yet. Edits are never uploaded from here: build one file, check and upload it in JOSM yourself, then record it.
      </p>
      <ol className="steps">
        <li>Choose the reports and build the .osc file.</li>
        <li>Open it in JOSM (File, Open), check each edit, and upload with the suggested comment.</li>
        <li>Record the changeset id here, plus the new node ids if you have them.</li>
      </ol>
      {error && <p className="error-line" role="alert">{error}</p>}
      {rows === null ? (
        <p className="muted">Loading.</p>
      ) : rows.length === 0 ? (
        <p className="empty">Nothing to upload. Accepted reports appear here until they're recorded or skipped.</p>
      ) : (
        <>
          <table className="osm-table">
            <thead>
              <tr>
                <th scope="col">
                  <input
                    type="checkbox"
                    aria-label="Select all"
                    checked={selected.size === rows.length}
                    onChange={(e) => setSelected(e.target.checked ? new Set(rows.map((r) => r.id)) : new Set())}
                  />
                </th>
                <th scope="col">Edit</th>
                <th scope="col">Where</th>
                <th scope="col">Accepted</th>
                <th scope="col">Saved .osc</th>
                <th scope="col"><span className="visually-hidden">Links</span></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const node = r.type === "wrong_cypher" && r.postboxId?.startsWith("osm_") ? Number(r.postboxId.slice(4)) : null;
                const url = idEditorUrl({ overpassId: node, lat: r.lat, lng: r.lng });
                return (
                  <tr key={r.id}>
                    <td><input type="checkbox" checked={selected.has(r.id)} onChange={() => toggle(r.id)} aria-label={`Include ${r.id}`} /></td>
                    <td>
                      {r.type === "missing_postbox" ? "Add a post box" : "Change cypher"}: {cypherName(r.finalMonarch)}
                      {r.finalReference && <>, ref {r.finalReference}</>}
                    </td>
                    <td>{r.type === "missing_postbox" && r.lat !== null && r.lng !== null ? coords(r.lat, r.lng) : <code>{r.postboxId}</code>}</td>
                    <td>{relativeTime(r.reviewedAtMs)}</td>
                    <td className={r.osmStatus === "changeset_failed" ? "warn" : undefined}>{r.osmStatus === "changeset_failed" ? "No, OSM was unreachable" : "Yes"}</td>
                    <td>{url && <a href={url} target="_blank" rel="noopener noreferrer">Open in iD</a>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <div className="actions">
            <button type="button" className="primary" onClick={() => void build()} disabled={busy || selected.size === 0}>
              Build .osc for {selected.size} report{selected.size === 1 ? "" : "s"}
            </button>
            <input
              className="inline-input"
              value={skipReason}
              onChange={(e) => setSkipReason(e.target.value)}
              placeholder="Why no upload is needed"
              maxLength={200}
              aria-label="Reason no upload is needed"
            />
            <button type="button" className="quiet" disabled={busy || selected.size === 0 || skipReason.trim() === ""} onClick={() => void skip([...selected], skipReason.trim())}>
              Mark {selected.size} as needing no upload
            </button>
          </div>
        </>
      )}

      {batch && (
        <section className="panel batch-result" aria-labelledby="batch-h">
          <h2 id="batch-h">{batch.nodeCount === 0 ? "Nothing to upload in this selection" : `${batch.nodeCount} edit${batch.nodeCount === 1 ? "" : "s"} ready`}</h2>
          <table className="osm-table">
            <thead>
              <tr>
                <th scope="col">Report</th>
                <th scope="col">Node</th>
                <th scope="col">Result</th>
                <th scope="col"><span className="visually-hidden">Action</span></th>
              </tr>
            </thead>
            <tbody>
              {batch.entries.map((e) => (
                <tr key={e.reportId} className={`entry entry-${e.status}`}>
                  <td>
                    {byId.get(e.reportId)?.type === "missing_postbox" ? "New box" : "Cypher"} <code>{e.reportId}</code>
                  </td>
                  <td>{e.nodeId === null ? "none" : e.nodeId < 0 ? `new (${e.nodeId})` : <a href={`https://www.openstreetmap.org/node/${e.nodeId}`} target="_blank" rel="noopener noreferrer">{e.nodeId}</a>}</td>
                  <td>
                    {STATUS_TEXT[e.status]}
                    {e.detail && <span className="muted small"> {e.detail}</span>}
                  </td>
                  <td>
                    {SKIP_REASON[e.status] && (
                      <button type="button" className="quiet" disabled={busy} onClick={() => void skip([e.reportId], SKIP_REASON[e.status] as string)}>
                        Mark done
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {doneEntries.length > 1 && (
            <div className="actions">
              <button type="button" disabled={busy} onClick={() => void markAllDone()}>
                Mark all {doneEntries.length} that OSM already has as done
              </button>
            </div>
          )}
          {batch.nodeCount > 0 && (
            <>
              <div className="actions">
                <button type="button" className="primary" onClick={() => saveFile(batch.filename, batch.osc)}>Download {batch.filename}</button>
                <span className="muted small">{batch.storagePath ? `Also saved to Storage as ${batch.storagePath}` : "Not saved to Storage"}</span>
              </div>
              <label className="field">
                <span className="field-label">Changeset comment</span>
                <span className="copy-row">
                  <input readOnly value={batch.suggestedComment} onFocus={(e) => e.target.select()} />
                  <button type="button" className="quiet" onClick={() => void navigator.clipboard.writeText(batch.suggestedComment).then(() => notify("Comment copied."))}>Copy</button>
                </span>
              </label>
              <h3>After uploading</h3>
              <label className="field">
                <span className="field-label">Changeset id</span>
                <input value={changeset} onChange={(e) => setChangeset(e.target.value)} inputMode="numeric" placeholder="Optional, e.g. 154012345" />
              </label>
              {createEntries.map((e) => (
                <label className="field" key={e.reportId}>
                  <span className="field-label">New node id for {e.reportId}</span>
                  <input
                    value={nodeIds[e.reportId] ?? ""}
                    onChange={(ev) => setNodeIds((m) => ({ ...m, [e.reportId]: ev.target.value }))}
                    inputMode="numeric"
                    placeholder="Optional. Lets a later import match it to this box"
                  />
                </label>
              ))}
              <div className="actions">
                <button type="button" className="primary" onClick={() => void recordUpload()} disabled={busy || uploadedIds.length === 0}>
                  Record {uploadedIds.length} as uploaded
                </button>
              </div>
            </>
          )}
        </section>
      )}
    </main>
  );
}
