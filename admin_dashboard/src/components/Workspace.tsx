import { useImperativeHandle, useMemo, useRef, useState, type Ref } from "react";
import type { ReportSummaryDto, ReviewReportResult, SessionDto } from "../../../functions/src/_reviewTypes";
import { api } from "../api.ts";
import { useResource } from "../hooks.ts";
import { buildReviewRequest, confirmBlocker, impactParam, initialDecision, type DecisionState } from "../decision.ts";
import type { Command, DecisionMode } from "../keys.ts";
import { cypherForDigit, cypherName } from "../monarchs.ts";
import { coords, dateTime, idEditorUrl, metres, relativeTime } from "../format.ts";
import { ReportMap } from "./ReportMap.tsx";
import { StreetView } from "./StreetView.tsx";
import { Photos } from "./Photos.tsx";
import { DecisionPanel } from "./DecisionPanel.tsx";
import { FlagsPanel, ImpactPanel, OutcomePanel, ReporterPanel } from "./Panels.tsx";

/** What the centre pane shows above the photos. */
export type CentreView = "map" | "street";

export interface WorkspaceHandle {
  mode(): DecisionMode;
  run(cmd: Command): void;
}

interface Props {
  summary: ReportSummaryDto;
  session: SessionDto;
  /** History: show the outcome instead of the decision form. */
  readOnly: boolean;
  /** Map or Street View; kept by the App so it carries across reports. */
  centre: CentreView;
  onCentre: (view: CentreView) => void;
  onDecided?: (summary: ReportSummaryDto, decision: DecisionState, result: ReviewReportResult) => void;
  handle?: Ref<WorkspaceHandle>;
}

const SEVERITY_ORDER = { high: 0, medium: 1, info: 2 } as const;

export function Workspace({ summary, session, readOnly, centre, onCentre, onDecided, handle }: Props) {
  const id = summary.id;
  const detail = useResource(`detail:${id}`, () => api.detail(id));
  const ctx = useResource(`context:${id}`, () => api.context(id));
  const [osmOn, setOsmOn] = useState(false);
  const osm = useResource(osmOn ? `osm:${id}` : null, () => api.osmNearby(id));
  const [decision, setDecision] = useState<DecisionState>(() => initialDecision(summary));
  const [photoOpen, setPhotoOpen] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [hint, setHint] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const noteRef = useRef<HTMLInputElement>(null);
  const referenceRef = useRef<HTMLInputElement>(null);

  const param = summary.type === "wrong_cypher" && !readOnly ? impactParam(decision.cypher) : null;
  const impact = useResource(param !== null ? `impact:${id}:${param}` : null, () => api.impact(id, param as string));

  const flags = useMemo(
    () => [...(ctx.data?.map.flags ?? []), ...(osm.data?.flags ?? [])].sort((a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity]),
    [ctx.data, osm.data],
  );
  const writesBlocked = session.maintenanceMode && !session.ignoreMaintenance;

  const changeDecision = (d: DecisionState) => {
    setDecision(d);
    setHint(null);
    setError(null);
  };

  const confirm = (override: boolean) => {
    if (busy || readOnly) return;
    const blocker = confirmBlocker({
      report: summary,
      decision,
      impactReady: impact.data !== undefined,
      flags,
      override,
      noteMax: session.noteMax,
      referenceMax: session.referenceMax,
      writesBlocked,
    });
    if (blocker) {
      setHint(blocker);
      return;
    }
    setBusy(true);
    setError(null);
    api.review(id, buildReviewRequest(decision)).then(
      (result) => onDecided?.(summary, decision, result),
      (e: Error) => {
        setBusy(false);
        setError(e.message);
      },
    );
  };

  const editorUrl = () =>
    summary.status === "pending"
      ? idEditorUrl({ overpassId: detail.data?.overpassId ?? null, lat: summary.lat, lng: summary.lng })
      : detail.data?.osmEditUrl ?? idEditorUrl({ lat: summary.lat, lng: summary.lng });

  useImperativeHandle(handle, () => ({
    mode: () => decision.mode,
    run: (cmd: Command) => {
      switch (cmd.type) {
        case "photos":
          if ((detail.data?.photos.length ?? 0) > 0) setPhotoOpen(0);
          return;
        case "osmLayer":
          // The layer is drawn on the map, so show the map first.
          if (centre === "street") onCentre("map");
          if (osm.error) osm.reload();
          else setOsmOn((on) => centre === "street" || !on);
          return;
        case "openEditor": {
          const url = editorUrl();
          if (url) window.open(url, "_blank", "noopener,noreferrer");
          return;
        }
        default:
          break;
      }
      if (readOnly || busy) return;
      switch (cmd.type) {
        case "stageAccept":
          changeDecision({ ...decision, mode: "accept" });
          return;
        case "stageReject":
          changeDecision({ ...decision, mode: "reject" });
          return;
        case "cypher": {
          const info = cmd.digit === 0 ? null : cypherForDigit(cmd.digit);
          if (cmd.digit !== 0 && !info) return;
          changeDecision({ ...decision, mode: "accept", cypher: info ? { kind: "key", key: info.key } : { kind: "plain" } });
          return;
        }
        case "preset": {
          const p = session.rejectPresets[cmd.index];
          if (p) changeDecision({ ...decision, mode: "reject", note: p });
          return;
        }
        case "confirm":
          confirm(cmd.override);
          return;
        case "cancel":
          (document.activeElement as HTMLElement | null)?.blur();
          if (decision.mode !== "idle") changeDecision({ ...decision, mode: "idle" });
          return;
        case "focusNote":
          if (decision.mode !== "idle") noteRef.current?.focus();
          return;
        case "focusReference":
          if (decision.mode === "accept") referenceRef.current?.focus();
          return;
        default:
          return;
      }
    },
  }));

  const d = detail.data;
  const osmState: "off" | "loading" | "on" | "error" = !osmOn ? "off" : osm.error ? "error" : osm.loading ? "loading" : "on";

  return (
    <>
      <section className="pane pane-centre" aria-label="Report">
        <header className="report-head">
          <h1>{summary.type === "missing_postbox" ? "Missing postbox" : <>Cypher on <code>{summary.postboxId}</code></>}</h1>
          <p className="report-sub">
            Reported {relativeTime(summary.createdAtMs)} by {summary.reporterName ?? "a player with no display name"}
          </p>
          {summary.status !== "pending" && <p className={`status-chip status-${summary.status}`}>{summary.status === "accepted" ? "Accepted" : "Rejected"}</p>}
        </header>

        <div className="centre-tools">
          <div className="seg" role="group" aria-label="Show">
            {(["map", "street"] as const).map((v) => (
              <button key={v} type="button" aria-pressed={centre === v} className={centre === v ? "is-on" : undefined} onClick={() => onCentre(v)}>
                {v === "map" ? "Map" : "Street View"}
              </button>
            ))}
          </div>
          <span className="muted small">Switch with <kbd>v</kbd></span>
        </div>

        {centre === "street" ? (
          <StreetView reportId={id} target={summary.type === "wrong_cypher" ? "box" : "spot"} reportedAtMs={summary.createdAtMs} />
        ) : ctx.error ? (
          <p className="error-line">Couldn't load the map context: {ctx.error.message}</p>
        ) : ctx.data ? (
          <ReportMap map={ctx.data.map} osmNodes={osm.data?.nodes ?? null} />
        ) : (
          <div className="map map-empty">Loading the map.</div>
        )}

        <h2 className="section-h">Photos</h2>
        {d ? (
          <Photos
            reportId={id}
            photos={ctx.data?.map.photos ?? d.photos}
            anchorKind={ctx.data?.map.anchor?.kind ?? null}
            open={photoOpen}
            onOpenChange={setPhotoOpen}
            purged={d.mediaPurged}
          />
        ) : (
          <p className="muted">{detail.error ? `Couldn't load the report: ${detail.error.message}` : "Loading."}</p>
        )}

        <h2 className="section-h">Details</h2>
        {d && (
          <dl className="facts">
            <dt>Reported</dt>
            <dd>{dateTime(d.createdAtMs)}</dd>
            {d.type === "missing_postbox" && d.lat !== null && d.lng !== null && (
              <>
                <dt>Location</dt>
                <dd>
                  {coords(d.lat, d.lng)}
                  {d.accuracyMeters !== null && <span className={d.accuracyMeters > 25 ? "warn" : "muted"}> GPS accurate to {metres(d.accuracyMeters)}</span>}
                </dd>
              </>
            )}
            {d.type === "wrong_cypher" && (
              <>
                <dt>Recorded cypher</dt>
                <dd>{cypherName(d.postbox?.monarch ?? d.currentMonarch)}</dd>
                <dt>Postbox</dt>
                <dd>
                  {d.postbox ? (
                    <>
                      {d.postbox.reference ? `Ref ${d.postbox.reference}` : "No reference"}
                      {d.postbox.county && <>, {d.postbox.county}</>}
                      {d.postbox.removedFromOsm && <strong className="warn">. Pruned from OSM: accepting restores it</strong>}
                      {d.postbox.correctedBy && <span className="muted">. Corrected before, {dateTime(d.postbox.correctedAtMs)}</span>}
                    </>
                  ) : (
                    <strong className="warn">This postbox no longer exists in our data</strong>
                  )}
                </dd>
                {d.overpassId !== null && (
                  <>
                    <dt>OSM node</dt>
                    <dd>
                      <a href={`https://www.openstreetmap.org/node/${d.overpassId}`} target="_blank" rel="noopener noreferrer">{d.overpassId}</a>
                    </dd>
                  </>
                )}
              </>
            )}
            <dt>Suggested cypher</dt>
            <dd>{d.hasSuggestedMonarch ? cypherName(d.suggestedMonarch) : "Not sure"}</dd>
            {d.suggestedReference && (
              <>
                <dt>Suggested reference</dt>
                <dd>{d.suggestedReference}</dd>
              </>
            )}
            <dt>Note</dt>
            <dd>{d.note ? <blockquote>{d.note}</blockquote> : <span className="muted">{d.mediaPurged ? "Removed by data retention" : "None"}</span>}</dd>
            <dt>Report id</dt>
            <dd><code>{d.id}</code></dd>
          </dl>
        )}
      </section>

      <aside className="pane pane-side" aria-label="Checks and decision">
        <FlagsPanel flags={flags} loading={ctx.loading} osmState={osmState} osmError={osm.error?.message} />
        {readOnly ? (
          d && <OutcomePanel detail={d} />
        ) : (
          <DecisionPanel
            report={summary}
            session={session}
            decision={decision}
            onChange={changeDecision}
            onConfirm={confirm}
            hint={writesBlocked ? "Maintenance mode is on, so reviews are paused." : hint}
            busy={busy}
            error={error}
            noteRef={noteRef}
            referenceRef={referenceRef}
          />
        )}
        {summary.type === "wrong_cypher" && !readOnly && (
          <ImpactPanel
            impact={impact.data}
            loading={impact.loading}
            error={impact.error}
            choiceLabel={param === null ? null : cypherName(param === "plain" ? null : param)}
          />
        )}
        <ReporterPanel ctx={ctx.data?.reporter} loading={ctx.loading} />
      </aside>
    </>
  );
}
