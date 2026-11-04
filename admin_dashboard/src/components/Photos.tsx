import { useEffect, useRef, useState } from "react";
import type { PhotoDto } from "../../../functions/src/_reviewTypes";
import { api } from "../api.ts";
import { usePhoto } from "../hooks.ts";
import { metres } from "../format.ts";

function photoCaption(p: PhotoDto, anchorKind: "reported" | "postbox" | null): string {
  const where = p.exifLat === null
    ? "No GPS in the photo"
    : p.distanceM === null
      ? "Has GPS"
      : `Taken ${metres(p.distanceM)} from ${anchorKind === "postbox" ? "the box" : "the reported spot"}`;
  const when = p.hoursBeforeReport === null
    ? ""
    // EXIF time has no zone, so allow for BST before calling it a mismatch.
    : Math.abs(p.hoursBeforeReport) < 1.5
      ? ", around the time of reporting"
      : p.hoursBeforeReport > 0
        ? `, ${p.hoursBeforeReport >= 48 ? `${Math.round(p.hoursBeforeReport / 24)} days` : `${p.hoursBeforeReport} h`} before reporting`
        : ", time doesn't match the report";
  return where + when;
}

function Thumb({ reportId, photo, caption, onOpen }: { reportId: string; photo: PhotoDto; caption: string; onOpen: () => void }) {
  const { url, error } = usePhoto(api.photoPath(reportId, photo.index));
  const far = photo.distanceM !== null && photo.distanceM > 50;
  return (
    <figure className="thumb">
      <button type="button" className="thumb-button" onClick={onOpen} aria-label={`Open photo ${photo.index + 1}`}>
        {url ? <img src={url} alt={`Photo ${photo.index + 1} from the reporter`} /> : <span className="thumb-placeholder">{error ? "Couldn't load" : "Loading"}</span>}
      </button>
      <figcaption className={far ? "is-warning" : undefined}>{caption}</figcaption>
    </figure>
  );
}

interface Props {
  reportId: string;
  photos: ReadonlyArray<PhotoDto>;
  anchorKind: "reported" | "postbox" | null;
  /** Index to open in the lightbox (driven by the "p" key), or null. */
  open: number | null;
  onOpenChange: (index: number | null) => void;
  purged: boolean;
}

export function Photos({ reportId, photos, anchorKind, open, onOpenChange, purged }: Props) {
  if (photos.length === 0) {
    return <p className="muted">{purged ? "Photos and note were removed 30 days after review (data retention)." : "No photos attached."}</p>;
  }
  return (
    <>
      <div className="thumbs">
        {photos.map((p) => (
          <Thumb key={p.index} reportId={reportId} photo={p} caption={photoCaption(p, anchorKind)} onOpen={() => onOpenChange(p.index)} />
        ))}
      </div>
      {open !== null && photos[open] && (
        <Lightbox
          reportId={reportId}
          photos={photos}
          index={open}
          caption={photoCaption(photos[open], anchorKind)}
          onIndex={onOpenChange}
        />
      )}
    </>
  );
}

function Lightbox({ reportId, photos, index, caption, onIndex }: { reportId: string; photos: ReadonlyArray<PhotoDto>; index: number; caption: string; onIndex: (i: number | null) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [zoomed, setZoomed] = useState(false);
  const { url, error } = usePhoto(api.photoPath(reportId, photos[index].index));
  const p = photos[index];

  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);
  useEffect(() => setZoomed(false), [index]);

  return (
    <dialog
      ref={ref}
      className="lightbox"
      aria-label={`Photo ${index + 1} of ${photos.length}`}
      onClose={() => onIndex(null)}
      onKeyDown={(e) => {
        if (e.key === "ArrowRight" && index < photos.length - 1) onIndex(index + 1);
        if (e.key === "ArrowLeft" && index > 0) onIndex(index - 1);
      }}
    >
      <div className={`lightbox-stage${zoomed ? " is-zoomed" : ""}`}>
        {url ? (
          <img src={url} alt={`Photo ${index + 1} from the reporter`} onClick={() => setZoomed((z) => !z)} />
        ) : (
          <p>{error ? `Couldn't load the photo: ${error}` : "Loading"}</p>
        )}
      </div>
      <div className="lightbox-bar">
        <span>
          Photo {index + 1} of {photos.length}. {caption}.
          {p.takenAt && <> Camera time {p.takenAt}.</>}
          {p.exifLat !== null && p.exifLng !== null && <> GPS {p.exifLat.toFixed(6)}, {p.exifLng.toFixed(6)}.</>}
        </span>
        <span className="lightbox-actions">
          <button type="button" onClick={() => onIndex(index - 1)} disabled={index === 0}>Previous</button>
          <button type="button" onClick={() => onIndex(index + 1)} disabled={index === photos.length - 1}>Next</button>
          <button type="button" onClick={() => setZoomed((z) => !z)}>{zoomed ? "Fit" : "Zoom"}</button>
          <button type="button" onClick={() => ref.current?.close()}>Close</button>
        </span>
      </div>
    </dialog>
  );
}
