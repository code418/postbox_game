import { Fragment } from "react";
import { Circle, CircleMarker, MapContainer, Polyline, Popup, TileLayer, Tooltip } from "react-leaflet";
import type { MapContextDto, OsmNearbyNodeDto } from "../../../functions/src/_reviewTypes";
import { cypherName } from "../monarchs.ts";
import { metres } from "../format.ts";

// Leaflet writes these into SVG attributes, where CSS variables don't
// resolve, so the map keeps its own copy of the palette.
const C = {
  red: "#C8102E",
  navy: "#0A1931",
  gold: "#E0A100",
  green: "#1D7348",
  grey: "#7A8494",
  violet: "#6B3FA0",
};

interface Props {
  map: MapContextDto;
  osmNodes: ReadonlyArray<OsmNearbyNodeDto> | null;
}

/** Everything around a report. Popups and tooltips are React children, never
 *  HTML strings: OSM tags, references and ids are untrusted text. */
export function ReportMap({ map, osmNodes }: Props) {
  const firstPhoto = map.photos.find((p) => p.exifLat !== null && p.exifLng !== null);
  const centre = map.anchor ?? (firstPhoto ? { lat: firstPhoto.exifLat as number, lng: firstPhoto.exifLng as number } : null);
  if (!centre) return <div className="map map-empty">No location to show: the box this report is about no longer exists.</div>;

  return (
    <div className="map-wrap">
      <MapContainer className="map" center={[centre.lat, centre.lng]} zoom={18} maxZoom={19} scrollWheelZoom>
        <TileLayer
          url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
          maxZoom={19}
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
        />
        {map.anchor && (
          <>
            <Circle center={[map.anchor.lat, map.anchor.lng]} radius={map.radiusM} pathOptions={{ color: C.navy, weight: 1, opacity: 0.25, fill: false }} />
            <Circle center={[map.anchor.lat, map.anchor.lng]} radius={30} pathOptions={{ color: C.navy, weight: 1, opacity: 0.6, dashArray: "4 4", fill: false }} />
            {map.accuracyMeters !== null && (
              <Circle center={[map.anchor.lat, map.anchor.lng]} radius={map.accuracyMeters} pathOptions={{ color: C.red, weight: 1, fillColor: C.red, fillOpacity: 0.08 }} />
            )}
          </>
        )}

        {map.postboxes.map((pb) => (
          <CircleMarker
            key={pb.id}
            center={[pb.lat, pb.lng]}
            radius={7}
            pathOptions={
              pb.removedFromOsm
                ? { color: C.grey, weight: 2, fillColor: "#fff", fillOpacity: 1, dashArray: "2 2" }
                : { color: "#fff", weight: 2, fillColor: pb.source === "user_report" ? C.violet : C.navy, fillOpacity: 1 }
            }
          >
            <Popup>
              <strong>{pb.id}</strong>
              <br />
              {cypherName(pb.monarch)}
              {pb.reference && <>, ref {pb.reference}</>}
              <br />
              {metres(pb.distanceM)} away{pb.removedFromOsm && ", pruned from OSM"}
            </Popup>
          </CircleMarker>
        ))}

        {map.reports.map((r) => (
          <CircleMarker
            key={r.id}
            center={[r.lat, r.lng]}
            radius={5}
            pathOptions={{ color: C.gold, weight: 2, fillColor: "#fff", fillOpacity: 0.9 }}
          >
            <Popup>
              Another {r.type === "missing_postbox" ? "missing-box" : "cypher"} report, {r.status}
              <br />
              {metres(r.distanceM)} away
            </Popup>
          </CircleMarker>
        ))}

        {osmNodes?.map((n) => (
          <CircleMarker
            key={`osm-${n.id}`}
            center={[n.lat, n.lon]}
            radius={10}
            pathOptions={{ color: n.lifecycle === "active" ? C.green : C.grey, weight: 2, fill: false }}
          >
            <Popup>
              <strong>OSM node {n.id}</strong> ({n.lifecycle})
              <br />
              {n.firestoreId ? `In our data as ${n.firestoreId}` : "Not in our data"}
              <table className="tag-table">
                <tbody>
                  {Object.entries(n.tags).map(([k, v]) => (
                    <tr key={k}>
                      <th>{k}</th>
                      <td>{v}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Popup>
          </CircleMarker>
        ))}

        {map.photos.map((p) =>
          p.exifLat !== null && p.exifLng !== null ? (
            <Fragment key={`photo-${p.index}`}>
              {map.anchor && (
                <Polyline positions={[[map.anchor.lat, map.anchor.lng], [p.exifLat, p.exifLng]]} pathOptions={{ color: C.gold, weight: 2, dashArray: "6 4" }} />
              )}
              <CircleMarker center={[p.exifLat, p.exifLng]} radius={6} pathOptions={{ color: C.navy, weight: 2, fillColor: C.gold, fillOpacity: 1 }}>
                <Tooltip permanent direction="right" offset={[8, 0]}>
                  Photo {p.index + 1}
                  {p.distanceM !== null && `, ${metres(p.distanceM)}`}
                </Tooltip>
              </CircleMarker>
            </Fragment>
          ) : null,
        )}

        {map.anchor && (
          <CircleMarker
            center={[map.anchor.lat, map.anchor.lng]}
            radius={8}
            pathOptions={{ color: "#fff", weight: 3, fillColor: map.anchor.kind === "reported" ? C.red : C.navy, fillOpacity: 1 }}
          >
            <Tooltip direction="top" offset={[0, -8]}>
              {map.anchor.kind === "reported" ? "Reported spot" : "This postbox"}
            </Tooltip>
          </CircleMarker>
        )}
      </MapContainer>
      <ul className="map-legend">
        <li><span className="dot" style={{ background: map.anchor?.kind === "postbox" ? C.navy : C.red }} />{map.anchor?.kind === "postbox" ? "This postbox" : "Reported spot"}</li>
        <li><span className="dot" style={{ background: C.navy }} />Postbox in our data</li>
        <li><span className="dot" style={{ background: C.violet }} />Added from a report</li>
        <li><span className="dot dot-hollow" style={{ borderColor: C.grey }} />Pruned from OSM</li>
        <li><span className="dot" style={{ background: C.gold }} />Photo position</li>
        <li><span className="dot dot-hollow" style={{ borderColor: C.gold }} />Other report</li>
        {osmNodes && <li><span className="dot dot-hollow" style={{ borderColor: C.green }} />Live OSM node</li>}
        <li className="legend-rings">Rings at 30 m and {map.radiusM} m</li>
      </ul>
    </div>
  );
}
