import type {
  CypherImpactDto,
  DuplicateFlagDto,
  ReportDetailDto,
  ReporterContextDto,
} from "../../../functions/src/_reviewTypes";
import { cypherName } from "../monarchs.ts";
import { dateTime, percent, relativeTime, signed } from "../format.ts";
import { api, saveFile, fetchBlob } from "../api.ts";

export function FlagsPanel({ flags, loading, osmState, osmError }: {
  flags: ReadonlyArray<DuplicateFlagDto>;
  loading: boolean;
  osmState: "off" | "loading" | "on" | "error";
  osmError?: string;
}) {
  return (
    <section className="panel" aria-labelledby="flags-h">
      <h2 id="flags-h">Checks</h2>
      {loading ? (
        <p className="muted">Looking around the spot.</p>
      ) : flags.length === 0 ? (
        <p className="ok-line">No duplicates or conflicts found in our data.</p>
      ) : (
        <ul className="flags">
          {flags.map((f, i) => (
            <li key={i} className={`flag flag-${f.severity}`}>
              <span className="flag-sev">{f.severity === "high" ? "Likely duplicate" : f.severity === "medium" ? "Check" : "Note"}</span>
              {f.message}
            </li>
          ))}
        </ul>
      )}
      <p className="muted small">
        {osmState === "off" && "Live OSM data isn't loaded. Press o to check OSM too."}
        {osmState === "loading" && "Asking OpenStreetMap. This can take up to half a minute."}
        {osmState === "on" && "Includes live OSM data."}
        {osmState === "error" && `${osmError ?? "Couldn't reach OpenStreetMap."} Press o to try again.`}
      </p>
    </section>
  );
}

export function ReporterPanel({ ctx, loading }: { ctx: ReporterContextDto | undefined; loading: boolean }) {
  if (loading || !ctx) {
    return (
      <section className="panel">
        <h2>Reporter</h2>
        <p className="muted">Loading.</p>
      </section>
    );
  }
  if (ctx.deletedAccount) {
    return (
      <section className="panel">
        <h2>Reporter</h2>
        <p>The reporter deleted their account. Their reports were anonymised.</p>
      </section>
    );
  }
  const accountAge = ctx.account?.createdAtMs != null ? relativeTime(ctx.account.createdAtMs).replace(" ago", " old") : null;
  const lowTrust = ctx.trustScore < 70;
  return (
    <section className="panel" aria-labelledby="reporter-h">
      <h2 id="reporter-h">Reporter</h2>
      <p className="reporter-name">
        {ctx.displayName ?? "No display name"}
        <code className="uid">{ctx.uid}</code>
      </p>
      <dl className="facts compact">
        <dt>Account</dt>
        <dd>
          {ctx.account ? (
            <>
              {accountAge ?? "Age unknown"}
              {ctx.account.providers.length > 0 && <>, signs in with {ctx.account.providers.map(providerName).join(" and ")}</>}
              {ctx.account.disabled && <strong className="warn"> Disabled</strong>}
            </>
          ) : (
            "Not found in Auth"
          )}
        </dd>
        <dt>Reports</dt>
        <dd>
          {ctx.reports.total} in total: {ctx.reports.accepted} accepted, {ctx.reports.rejected} rejected, {ctx.reports.pending} pending.
          {ctx.reports.acceptanceRate !== null && <> Acceptance {percent(ctx.reports.acceptanceRate)}.</>}
        </dd>
        <dt>Trust</dt>
        <dd className={lowTrust ? "warn" : undefined}>
          {ctx.trustScore} of 100{ctx.trustScoreIsDefault && ", never lowered"}
        </dd>
        <dt>Flags</dt>
        <dd className={ctx.flags.unreviewed > 0 ? "warn" : undefined}>
          {ctx.flags.total === 0 ? "No anti-cheat flags" : `${ctx.flags.total} anti-cheat flag${ctx.flags.total === 1 ? "" : "s"}, ${ctx.flags.unreviewed} unreviewed`}
          {ctx.flags.recent.length > 0 && (
            <span className="muted small"> Latest: {ctx.flags.recent[0].reasons.join(", ") || ctx.flags.recent[0].severity}</span>
          )}
        </dd>
        {ctx.stats && (
          <>
            <dt>Playing</dt>
            <dd>
              {ctx.stats.uniquePostboxesClaimed} boxes, {ctx.stats.lifetimePoints} points, streak {ctx.stats.streak}
              {ctx.stats.lastClaimDate && <>, last claim {ctx.stats.lastClaimDate}</>}
            </dd>
          </>
        )}
        {ctx.claimedThisBox && (
          <>
            <dt>This box</dt>
            <dd>
              {ctx.claimedThisBox.count === 0
                ? "Never claimed it"
                : `Claimed it ${ctx.claimedThisBox.count} time${ctx.claimedThisBox.count === 1 ? "" : "s"}, last ${ctx.claimedThisBox.lastDailyDate}`}
            </dd>
          </>
        )}
      </dl>
    </section>
  );
}

function providerName(id: string): string {
  return { "google.com": "Google", "apple.com": "Apple", password: "email" }[id] ?? id;
}

export function ImpactPanel({ impact, loading, error, choiceLabel }: { impact: CypherImpactDto | undefined; loading: boolean; error: Error | undefined; choiceLabel: string | null }) {
  return (
    <section className="panel" aria-labelledby="impact-h" aria-live="polite">
      <h2 id="impact-h">If you accept</h2>
      {choiceLabel === null ? (
        <p className="muted">Pick a cypher to see what changes for players.</p>
      ) : loading ? (
        <p className="muted">Working out the rescore for {choiceLabel}.</p>
      ) : error ? (
        <p className="error-line">Couldn't preview the rescore: {error.message}</p>
      ) : impact ? (
        <>
          <p className="impact-headline">
            {impact.claimsToRewrite === 0
              ? `No claims change: all ${impact.totalClaims} already score as ${choiceLabel}.`
              : `${impact.claimsToRewrite} of ${impact.totalClaims} claims are rewritten as ${choiceLabel} (${impact.newPoints} pts each).`}
          </p>
          <p>
            {impact.affectedUsers === 0
              ? "No player's totals change."
              : `${impact.affectedUsers} player${impact.affectedUsers === 1 ? "'s" : "s'"} totals change by ${signed(impact.totalDelta)} points in all, and their leaderboards are recalculated.`}
            {impact.deletedAccountClaims > 0 && ` ${impact.deletedAccountClaims} claim${impact.deletedAccountClaims === 1 ? " is" : "s are"} from deleted accounts and only get the new points.`}
          </p>
          {impact.users.some((u) => u.delta !== 0) && (
            <table className="impact-table">
              <thead>
                <tr>
                  <th scope="col">Player</th>
                  <th scope="col" className="num">Claims</th>
                  <th scope="col" className="num">Change</th>
                  <th scope="col" className="num">Lifetime</th>
                </tr>
              </thead>
              <tbody>
                {impact.users.filter((u) => u.delta !== 0).map((u) => (
                  <tr key={u.uid}>
                    <td>{u.displayName ?? <code>{u.uid.slice(0, 8)}</code>}</td>
                    <td className="num">{u.claims}</td>
                    <td className={`num ${u.delta < 0 ? "neg" : "pos"}`}>{signed(u.delta)}</td>
                    <td className="num">{u.lifetimePointsBefore === null ? "unknown" : `${u.lifetimePointsBefore} to ${u.lifetimePointsAfter}`}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {impact.usersTruncated && <p className="muted small">Showing the largest changes only.</p>}
        </>
      ) : null}
    </section>
  );
}

export function OutcomePanel({ detail }: { detail: ReportDetailDto }) {
  const accepted = detail.status === "accepted";
  const downloadOsc = async () => saveFile(`report-${detail.id}.osc`, await fetchBlob(api.oscPath(detail.id)));
  return (
    <section className="panel" aria-labelledby="outcome-h">
      <h2 id="outcome-h">{accepted ? "Accepted" : "Rejected"}</h2>
      <dl className="facts compact">
        <dt>By</dt>
        <dd>{detail.reviewedByName ?? detail.reviewedBy ?? "unknown"}, {dateTime(detail.reviewedAtMs)}</dd>
        {accepted && (
          <>
            <dt>Cypher</dt>
            <dd>{cypherName(detail.finalMonarch)}</dd>
            {detail.finalReference && (
              <>
                <dt>Reference</dt>
                <dd>{detail.finalReference}</dd>
              </>
            )}
          </>
        )}
        {detail.reviewNote && (
          <>
            <dt>Note to reporter</dt>
            <dd>{detail.reviewNote}</dd>
          </>
        )}
        {detail.rescoredClaims !== null && (
          <>
            <dt>Rescore</dt>
            <dd>
              {detail.rescoredClaims} claims rewritten, {detail.affectedUsers ?? 0} players affected, {signed(detail.rescoreTotalDelta ?? 0)} points
            </dd>
          </>
        )}
        {accepted && (
          <>
            <dt>OSM</dt>
            <dd className={detail.osmStatus === "changeset_failed" ? "warn" : undefined}>
              {detail.osmUploadedAtMs !== null
                ? `Uploaded ${dateTime(detail.osmUploadedAtMs)}${detail.osmChangesetId ? ` in changeset ${detail.osmChangesetId}` : ""}`
                : detail.osmSkippedAtMs !== null
                  ? `No upload needed: ${detail.osmSkipReason ?? "skipped"}`
                  : detail.osmStatus === "changeset_failed"
                    ? "No .osc was generated (OSM was unreachable). Build one from OSM edits."
                    : "Waiting for upload. Find it under OSM edits."}
            </dd>
          </>
        )}
      </dl>
      {accepted && (
        <p className="actions">
          {detail.osmEditUrl && <a className="button" href={detail.osmEditUrl} target="_blank" rel="noopener noreferrer">Open in iD</a>}
          {detail.osmChangesetPath && <button type="button" onClick={() => void downloadOsc()}>Download .osc</button>}
        </p>
      )}
    </section>
  );
}
