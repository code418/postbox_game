import { useEffect, useRef } from "react";
import { api } from "../api.ts";
import { useResource } from "../hooks.ts";
import { metres, monthYear, yearsBefore } from "../format.ts";

/** A panorama further than this from the spot often doesn't show the box. */
const FAR_M = 25;
/** Imagery this many years older than the report may predate the box. */
const OLD_YEARS = 3;

interface Props {
  reportId: string;
  /** What the camera is aimed at: a cypher report's box, or a reported spot. */
  target: "box" | "spot";
  reportedAtMs: number | null;
}

/** Google Street View from the nearest outdoor panorama, aimed at the spot.
 *  Without a Maps key on the server it links out to Google Maps instead. */
export function StreetView({ reportId, target, reportedAtMs }: Props) {
  const sv = useResource(`streetview:${reportId}`, () => api.streetView(reportId));
  const wrap = useRef<HTMLDivElement>(null);
  const frame = useRef<HTMLIFrameElement>(null);

  // Keys pressed while the cross-origin frame has focus never reach the
  // dashboard, so j/k/v would stop working after the first drag. Take focus
  // straight back: the panorama still gets mouse drags and clicks.
  useEffect(() => {
    const onBlur = () =>
      window.setTimeout(() => {
        if (frame.current && document.activeElement === frame.current) wrap.current?.focus({ preventScroll: true });
      }, 0);
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, []);

  const label = target === "box" ? "the box" : "the reported spot";
  if (sv.error) {
    return (
      <div className="map map-empty sv-message">
        <p>Couldn't load Street View: {sv.error.message}</p>
        <button type="button" onClick={sv.reload}>Try again</button>
      </div>
    );
  }
  if (!sv.data) return <div className="map map-empty">Finding the nearest Street View image.</div>;

  const d = sv.data;
  if (d.status !== "ok") {
    return (
      <div className="map map-empty sv-message">
        <p>{d.status === "none" ? `Google has no outdoor Street View within ${d.radiusM} m of ${label}.` : "Street View can't show here yet: the server has no Google Maps key."}</p>
        <a className="button" href={d.mapsUrl} target="_blank" rel="noopener noreferrer">
          {d.status === "none" ? "Look in Google Maps anyway" : "Open Street View in Google Maps"}
        </a>
        {d.status === "not_configured" && <p className="muted small">Set GOOGLE_MAPS_API_KEY and restart the server to see it here. The README has the steps.</p>}
      </div>
    );
  }

  const when = monthYear(d.date);
  const age = yearsBefore(d.date, reportedAtMs);
  return (
    <div className="map-wrap">
      <div ref={wrap} tabIndex={-1} className="sv-frame-wrap">
        <iframe
          ref={frame}
          className="map streetview"
          src={d.embedUrl}
          title={`Street View facing ${label}`}
          allowFullScreen
          referrerPolicy="strict-origin-when-cross-origin"
          sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox"
        />
      </div>
      <p className="sv-caption">
        <span>
          Taken {metres(d.distanceM)} from {label}
          {when && ` in ${when}`}, facing it. Drag to look around.
        </span>
        <a href={d.mapsUrl} target="_blank" rel="noopener noreferrer">Open in Google Maps</a>
      </p>
      {d.distanceM > FAR_M && <p className="sv-note">The nearest image is {metres(d.distanceM)} away, so the box may be out of shot.</p>}
      {age !== null && age >= OLD_YEARS && <p className="sv-note">This imagery is {age} years older than the report, so the street may have changed since.</p>}
    </div>
  );
}
