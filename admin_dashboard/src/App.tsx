import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReportSummaryDto, ReviewReportResult, SessionDto } from "../../functions/src/_reviewTypes";
import { ApiError, api, fetchBlob, loadToken, saveFile } from "./api.ts";
import { cached, invalidate, useResource } from "./hooks.ts";
import { keyToCommand, type Command, type View } from "./keys.ts";
import type { DecisionState } from "./decision.ts";
import { cypherName } from "./monarchs.ts";
import { signed } from "./format.ts";
import { Workspace, type WorkspaceHandle } from "./components/Workspace.tsx";
import { HistoryList, Queue, applyQueueFilters, type HistoryFilters, type QueueFilters } from "./components/Lists.tsx";
import { OsmView } from "./components/OsmView.tsx";
import { BatchRejectDialog, HelpDialog, TopBar, Toasts, type Toast } from "./components/Chrome.tsx";

const POLL_MS = 30_000;
const TOAST_MS = 9_000;
const GO_PREFIX_MS = 1_200;

export function App() {
  const [hasToken] = useState(() => loadToken() !== null);
  const session = useResource(hasToken ? "session" : null, api.session);

  if (!hasToken || (session.error instanceof ApiError && session.error.status === 401)) {
    return (
      <main className="gate">
        <h1>Open the link from your terminal</h1>
        <p>
          The review server prints a link with a one-time key when it starts. Open that link, or restart the server with
          <code> npm run review-dashboard -- --reviewer &lt;uid&gt;</code> in <code>functions/</code>.
        </p>
      </main>
    );
  }
  if (session.error) {
    return (
      <main className="gate">
        <h1>Can't reach the review server</h1>
        <p>{session.error.message}</p>
        <button type="button" onClick={session.reload}>Try again</button>
      </main>
    );
  }
  if (!session.data) return <main className="gate"><p className="muted">Connecting to the review server.</p></main>;
  return <Dashboard session={session.data} />;
}

interface HistoryState {
  rows: ReportSummaryDto[];
  nextBefore: number | null;
  loading: boolean;
  error: string | null;
}

function Dashboard({ session }: { session: SessionDto }) {
  const [view, setView] = useState<View>("queue");
  const [pending, setPending] = useState<ReportSummaryDto[] | null>(null);
  const [pendingError, setPendingError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filters, setFilters] = useState<QueueFilters>({ type: "all", photosOnly: false });
  const [batch, setBatch] = useState<Set<string>>(new Set());
  const [batchOpen, setBatchOpen] = useState(false);
  const [help, setHelp] = useState(false);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [historyFilters, setHistoryFilters] = useState<HistoryFilters>({ status: "all", type: "all" });
  const [history, setHistory] = useState<HistoryState>({ rows: [], nextBefore: null, loading: false, error: null });
  const [historySelected, setHistorySelected] = useState<string | null>(null);
  const workspace = useRef<WorkspaceHandle>(null);
  const goTimer = useRef<number | null>(null);
  const toastSeq = useRef(0);

  const toast = useCallback((t: Omit<Toast, "id">) => {
    const id = ++toastSeq.current;
    setToasts((ts) => [...ts.slice(-3), { ...t, id }]);
    window.setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== id)), TOAST_MS);
  }, []);

  // ── pending queue ─────────────────────────────────────────────────────────
  const loadPending = useCallback(() => {
    api.pending().then(
      (r) => {
        setPending(r.reports);
        setPendingError(null);
      },
      (e: Error) => setPendingError(e.message),
    );
  }, []);
  useEffect(() => {
    loadPending();
    const t = window.setInterval(loadPending, POLL_MS);
    return () => window.clearInterval(t);
  }, [loadPending]);

  const visible = useMemo(() => (pending ? applyQueueFilters(pending, filters) : []), [pending, filters]);

  // Keep a valid selection: the first visible report when the current one goes.
  useEffect(() => {
    if (visible.length === 0) setSelectedId(null);
    else if (selectedId === null || !visible.some((r) => r.id === selectedId)) setSelectedId(visible[0].id);
  }, [visible, selectedId]);

  // Warm the next report's detail and context (Firestore only, never Overpass).
  useEffect(() => {
    const i = visible.findIndex((r) => r.id === selectedId);
    const next = i >= 0 ? visible[i + 1] : undefined;
    if (!next) return;
    const t = window.setTimeout(() => {
      void cached(`detail:${next.id}`, () => api.detail(next.id)).catch(() => undefined);
      void cached(`context:${next.id}`, () => api.context(next.id)).catch(() => undefined);
    }, 400);
    return () => window.clearTimeout(t);
  }, [visible, selectedId]);

  const forgetReport = (id: string) => {
    invalidate(`detail:${id}`);
    invalidate(`impact:${id}`);
    // Neighbouring reports list this one's status in their context.
    invalidate("context:");
  };

  const onDecided = (summary: ReportSummaryDto, decision: DecisionState, result: ReviewReportResult) => {
    const i = visible.findIndex((r) => r.id === summary.id);
    const next = visible[i + 1] ?? visible[i - 1] ?? null;
    setSelectedId(next?.id ?? null);
    setPending((p) => p?.filter((r) => r.id !== summary.id) ?? p);
    setBatch((b) => {
      const n = new Set(b);
      n.delete(summary.id);
      return n;
    });
    forgetReport(summary.id);
    setHistory((h) => ({ ...h, rows: [] }));

    if (result.status === "rejected") {
      toast({ text: "Report rejected.", tone: "ok" });
    } else {
      const links: NonNullable<Toast["links"]> = [{ label: "Open in iD", href: result.osmEditUrl }];
      if (result.osmChangesetPath) {
        links.push({
          label: "Download .osc",
          onClick: () => void fetchBlob(api.oscPath(summary.id)).then((b) => saveFile(`report-${summary.id}.osc`, b)),
        });
      }
      const text = summary.type === "missing_postbox"
        ? "Postbox added."
        : `Cypher changed to ${cypherName(decision.cypher.kind === "key" ? decision.cypher.key : null)}. ` +
          (result.rescoredClaims === 0
            ? "No claims needed rescoring."
            : `${result.rescoredClaims} claims rescored, ${result.affectedUsers} players' totals changed (${signed(result.rescoreTotalDelta)} points).`);
      toast({ text: result.osmChangesetPath ? text : `${text} No .osc was made, so build one under OSM edits.`, tone: "ok", links });
    }
    loadPending();
  };

  const batchReject = async (note: string) => {
    const ids = [...batch];
    const { results } = await api.batchReject(ids, note);
    const ok = results.filter((r) => r.ok).map((r) => r.reportId);
    const failed = results.filter((r) => !r.ok);
    setPending((p) => p?.filter((r) => !ok.includes(r.id)) ?? p);
    setBatch(new Set(failed.map((f) => f.reportId)));
    ok.forEach(forgetReport);
    setHistory((h) => ({ ...h, rows: [] }));
    toast({
      text: `Rejected ${ok.length} report${ok.length === 1 ? "" : "s"}.${failed.length ? ` ${failed.length} failed: ${failed[0].message}` : ""}`,
      tone: failed.length ? "error" : "ok",
    });
    loadPending();
  };

  // ── history ───────────────────────────────────────────────────────────────
  const loadHistory = useCallback((reset: boolean, before: number | null) => {
    setHistory((h) => ({ ...h, loading: true }));
    api.history({ ...historyFilters, before: reset ? null : before }).then(
      (r) => setHistory((h) => ({ rows: reset ? r.reports : [...h.rows, ...r.reports], nextBefore: r.nextBefore, loading: false, error: null })),
      (e: Error) => setHistory((h) => ({ ...h, loading: false, error: e.message })),
    );
  }, [historyFilters]);
  useEffect(() => {
    if (view === "history") loadHistory(true, null);
  }, [view, loadHistory]);
  useEffect(() => {
    if (history.rows.length > 0 && (historySelected === null || !history.rows.some((r) => r.id === historySelected))) {
      setHistorySelected(history.rows[0].id);
    }
  }, [history.rows, historySelected]);

  // ── keyboard ──────────────────────────────────────────────────────────────
  const move = (delta: number) => {
    const rows = view === "history" ? history.rows : visible;
    const current = view === "history" ? historySelected : selectedId;
    if (rows.length === 0) return;
    const i = rows.findIndex((r) => r.id === current);
    const next = rows[Math.min(rows.length - 1, Math.max(0, (i < 0 ? 0 : i) + delta))];
    if (view === "history") setHistorySelected(next.id);
    else setSelectedId(next.id);
  };

  const toggleBatch = (id: string) =>
    setBatch((b) => {
      const n = new Set(b);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  const dispatch = (cmd: Command) => {
    switch (cmd.type) {
      case "next":
        return move(1);
      case "prev":
        return move(-1);
      case "view":
        return setView(cmd.view);
      case "help":
        return setHelp(true);
      case "goPrefix":
        goTimer.current = window.setTimeout(() => {
          goTimer.current = null;
        }, GO_PREFIX_MS);
        return;
      case "toggleBatch":
        if (view === "queue" && selectedId) toggleBatch(selectedId);
        return;
      case "batchReject":
        if (view === "queue" && batch.size > 0) setBatchOpen(true);
        return;
      default:
        if (view !== "osm") workspace.current?.run(cmd);
    }
  };
  const dispatchRef = useRef(dispatch);
  dispatchRef.current = dispatch;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Open dialogs (lightbox, help, batch reject) handle their own keys.
      if (document.querySelector("dialog[open]")) return;
      const t = e.target as HTMLElement | null;
      const inTextField =
        (t instanceof HTMLInputElement && !["checkbox", "radio", "button", "submit"].includes(t.type)) ||
        t instanceof HTMLTextAreaElement ||
        t instanceof HTMLSelectElement ||
        t?.isContentEditable === true;
      const goPending = goTimer.current !== null;
      if (goPending && goTimer.current !== null) {
        window.clearTimeout(goTimer.current);
        goTimer.current = null;
      }
      const cmd = keyToCommand(
        { key: e.key, shiftKey: e.shiftKey, ctrlKey: e.ctrlKey, metaKey: e.metaKey, altKey: e.altKey, inTextField },
        workspace.current?.mode() ?? "idle",
        goPending,
      );
      if (!cmd) return;
      e.preventDefault();
      dispatchRef.current(cmd);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // ── render ────────────────────────────────────────────────────────────────
  const queueSelected = visible.find((r) => r.id === selectedId) ?? null;
  const historyRow = history.rows.find((r) => r.id === historySelected) ?? null;
  const shown = view === "history" ? historyRow : queueSelected;

  return (
    <div className="app">
      <TopBar session={session} view={view} onView={setView} pendingCount={pending?.length ?? null} onHelp={() => setHelp(true)} />
      {view === "osm" ? (
        <OsmView notify={(text) => toast({ text, tone: "ok" })} />
      ) : (
        <div className="panes">
          {view === "queue" ? (
            <Queue
              rows={visible}
              total={pending?.length ?? 0}
              selectedId={selectedId}
              batch={batch}
              filters={filters}
              onFilters={setFilters}
              onSelect={setSelectedId}
              onToggleBatch={toggleBatch}
              onBatchReject={() => setBatchOpen(true)}
              onClearBatch={() => setBatch(new Set())}
              loading={pending === null}
              error={pendingError}
            />
          ) : (
            <HistoryList
              rows={history.rows}
              selectedId={historySelected}
              filters={historyFilters}
              onFilters={setHistoryFilters}
              onSelect={setHistorySelected}
              onMore={() => loadHistory(false, history.nextBefore)}
              hasMore={history.nextBefore !== null}
              loading={history.loading}
              error={history.error}
            />
          )}
          {shown ? (
            <Workspace
              key={`${view}:${shown.id}`}
              summary={shown}
              session={session}
              readOnly={view === "history"}
              onDecided={onDecided}
              handle={workspace}
            />
          ) : (
            <section className="pane pane-empty">
              <p>{view === "queue" ? (pending === null ? "Loading the queue." : "All caught up.") : "Pick a reviewed report."}</p>
            </section>
          )}
        </div>
      )}
      <Toasts toasts={toasts} onDismiss={(id) => setToasts((ts) => ts.filter((t) => t.id !== id))} />
      {help && <HelpDialog onClose={() => setHelp(false)} />}
      {batchOpen && (
        <BatchRejectDialog
          count={batch.size}
          presets={session.rejectPresets}
          noteMax={session.noteMax}
          onConfirm={batchReject}
          onClose={() => setBatchOpen(false)}
        />
      )}
    </div>
  );
}
