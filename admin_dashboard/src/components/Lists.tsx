import { useEffect, useRef } from "react";
import type { ReportSummaryDto } from "../../../functions/src/_reviewTypes";
import { cypherName } from "../monarchs.ts";
import { relativeTime } from "../format.ts";

export interface QueueFilters {
  type: "all" | "missing_postbox" | "wrong_cypher";
  photosOnly: boolean;
}

export function applyQueueFilters(rows: ReadonlyArray<ReportSummaryDto>, f: QueueFilters): ReportSummaryDto[] {
  return rows.filter((r) => (f.type === "all" || r.type === f.type) && (!f.photosOnly || r.photoCount > 0));
}

function rowTitle(r: ReportSummaryDto): string {
  // Once accepted, what was applied matters more than what was suggested.
  const accepted = r.status === "accepted";
  if (r.type === "missing_postbox") {
    if (accepted) return `New box, ${cypherName(r.finalMonarch)}`;
    return r.hasSuggestedMonarch ? `New box, ${cypherName(r.suggestedMonarch)}` : "New box, cypher unknown";
  }
  const to = accepted ? cypherName(r.finalMonarch) : r.hasSuggestedMonarch ? cypherName(r.suggestedMonarch) : "not sure";
  return `${cypherName(r.currentMonarch)} to ${to}`;
}

function Row({ r, selected, inBatch, onSelect, onToggleBatch, showOutcome }: {
  r: ReportSummaryDto;
  selected: boolean;
  inBatch: boolean | null;
  onSelect: () => void;
  onToggleBatch?: () => void;
  showOutcome: boolean;
}) {
  const ref = useRef<HTMLLIElement>(null);
  useEffect(() => {
    if (selected) ref.current?.scrollIntoView({ block: "nearest" });
  }, [selected]);
  return (
    <li ref={ref} className={`row${selected ? " is-selected" : ""}${inBatch ? " in-batch" : ""}`}>
      {inBatch !== null && (
        <input type="checkbox" checked={inBatch} onChange={onToggleBatch} aria-label={`Add ${r.id} to the batch`} tabIndex={-1} />
      )}
      <button type="button" className="row-main" onClick={onSelect} aria-current={selected ? "true" : undefined}>
        <span className={`row-kind kind-${r.type}`} aria-hidden="true" />
        <span className="row-text">
          <span className="row-title">{rowTitle(r)}</span>
          <span className="row-meta">
            <span>{showOutcome ? (r.status === "accepted" ? "Accepted" : "Rejected") : relativeTime(r.createdAtMs)}</span>
            {showOutcome && <span>{relativeTime(r.reviewedAtMs)}</span>}
            <span>{r.reporterName ?? "no name"}</span>
            {r.photoCount > 0 && <span>{r.photoCount} photo{r.photoCount === 1 ? "" : "s"}</span>}
            {showOutcome && r.osmStatus === "changeset_failed" && <span className="warn">no .osc</span>}
          </span>
        </span>
      </button>
    </li>
  );
}

export function Queue({ rows, total, selectedId, batch, filters, onFilters, onSelect, onToggleBatch, onBatchReject, onClearBatch, loading, error }: {
  rows: ReadonlyArray<ReportSummaryDto>;
  total: number;
  selectedId: string | null;
  batch: ReadonlySet<string>;
  filters: QueueFilters;
  onFilters: (f: QueueFilters) => void;
  onSelect: (id: string) => void;
  onToggleBatch: (id: string) => void;
  onBatchReject: () => void;
  onClearBatch: () => void;
  loading: boolean;
  error: string | null;
}) {
  return (
    <nav className="pane pane-list" aria-label="Pending reports">
      <div className="list-tools">
        <div className="seg" role="group" aria-label="Report type">
          {(["all", "missing_postbox", "wrong_cypher"] as const).map((t) => (
            <button key={t} type="button" aria-pressed={filters.type === t} className={filters.type === t ? "is-on" : undefined} onClick={() => onFilters({ ...filters, type: t })}>
              {t === "all" ? "All" : t === "missing_postbox" ? "New boxes" : "Cyphers"}
            </button>
          ))}
        </div>
        <label className="check">
          <input type="checkbox" checked={filters.photosOnly} onChange={(e) => onFilters({ ...filters, photosOnly: e.target.checked })} />
          With photos
        </label>
      </div>
      <p className="list-count muted small">
        {rows.length === total ? `${total} waiting, oldest first` : `${rows.length} of ${total} waiting, oldest first`}
      </p>
      {error && <p className="error-line">{error}</p>}
      {!loading && rows.length === 0 && !error && (
        <p className="empty">{total === 0 ? "Nothing to review. New reports appear here on their own." : "No reports match these filters."}</p>
      )}
      <ul className="rows">
        {rows.map((r) => (
          <Row key={r.id} r={r} selected={r.id === selectedId} inBatch={batch.has(r.id)} onSelect={() => onSelect(r.id)} onToggleBatch={() => onToggleBatch(r.id)} showOutcome={false} />
        ))}
      </ul>
      {batch.size > 0 && (
        <div className="batch-bar">
          <span>{batch.size} in the batch</span>
          <button type="button" className="danger" onClick={onBatchReject}>
            Reject {batch.size} <kbd>Shift+R</kbd>
          </button>
          <button type="button" className="quiet" onClick={onClearBatch}>Clear</button>
        </div>
      )}
    </nav>
  );
}

export interface HistoryFilters {
  status: "all" | "accepted" | "rejected";
  type: "all" | "missing_postbox" | "wrong_cypher";
}

export function HistoryList({ rows, selectedId, filters, onFilters, onSelect, onMore, hasMore, loading, error }: {
  rows: ReadonlyArray<ReportSummaryDto>;
  selectedId: string | null;
  filters: HistoryFilters;
  onFilters: (f: HistoryFilters) => void;
  onSelect: (id: string) => void;
  onMore: () => void;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
}) {
  return (
    <nav className="pane pane-list" aria-label="Reviewed reports">
      <div className="list-tools">
        <div className="seg" role="group" aria-label="Outcome">
          {(["all", "accepted", "rejected"] as const).map((s) => (
            <button key={s} type="button" aria-pressed={filters.status === s} className={filters.status === s ? "is-on" : undefined} onClick={() => onFilters({ ...filters, status: s })}>
              {s === "all" ? "All" : s === "accepted" ? "Accepted" : "Rejected"}
            </button>
          ))}
        </div>
        <select value={filters.type} onChange={(e) => onFilters({ ...filters, type: e.target.value as HistoryFilters["type"] })} aria-label="Report type">
          <option value="all">All types</option>
          <option value="missing_postbox">New boxes</option>
          <option value="wrong_cypher">Cyphers</option>
        </select>
      </div>
      {error && <p className="error-line">{error}</p>}
      {!loading && rows.length === 0 && !error && <p className="empty">No reviewed reports match these filters.</p>}
      <ul className="rows">
        {rows.map((r) => (
          <Row key={r.id} r={r} selected={r.id === selectedId} inBatch={null} onSelect={() => onSelect(r.id)} showOutcome />
        ))}
      </ul>
      {hasMore && (
        <button type="button" className="quiet more" onClick={onMore} disabled={loading}>
          {loading ? "Loading" : "Load older reviews"}
        </button>
      )}
    </nav>
  );
}
