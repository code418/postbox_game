import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:exif/exif.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// A photo the user has picked but not yet uploaded. EXIF GPS / capture time
/// are extracted on selection so the report screen can show "location in this
/// photo: …" hints before submitting.
class PendingPhoto {
  PendingPhoto({
    required this.bytes,
    required this.contentType,
    this.exifLat,
    this.exifLng,
    this.takenAt,
  });

  final Uint8List bytes;
  final String contentType;
  final double? exifLat;
  final double? exifLng;
  /// Raw EXIF DateTimeOriginal string (e.g. "2026:05:11 10:30:00"), if present.
  final String? takenAt;

  bool get hasLocation => exifLat != null && exifLng != null;
  int get sizeBytes => bytes.length;
}

/// Marker passed to [ReportRepository.submitWrongCypher] /
/// [ReportRepository.submitMissingPostbox] to mean "the postbox has no cypher"
/// (a plain box), as distinct from `null` which means "I'm not sure".
const String plainCypher = '__PLAIN__';

/// Picks photos, reads their EXIF, uploads them to Cloud Storage, and calls the
/// `submitReport` Cloud Function. Static helpers keep this stateless.
class ReportRepository {
  ReportRepository._();

  static const int maxPhotos = 3;
  static const int maxPhotoBytes = 10 * 1024 * 1024;

  /// Maximum length of the free-text note field. MUST match the server-side
  /// `NOTE_MAX` in functions/src/reports.ts — submitReport rejects longer
  /// notes. Used as the TextField `maxLength` so the UI can't get out of
  /// step with what the server will accept.
  static const int maxNoteChars = 280;

  /// Maximum length of the optional postbox-reference field (e.g. "SW1A 1").
  /// MUST match the server-side `REFERENCE_MAX` in functions/src/reports.ts.
  static const int maxReferenceChars = 40;

  static final ImagePicker _picker = ImagePicker();

  /// Picks one or more photos from [source]. For the gallery this may return
  /// several; for the camera it returns at most one. EXIF is parsed eagerly.
  /// Photos larger than [maxPhotoBytes] are skipped.
  static Future<List<PendingPhoto>> pickPhotos({
    required ImageSource source,
    int remainingSlots = maxPhotos,
  }) async {
    if (remainingSlots <= 0) return const [];
    final List<XFile> files;
    if (source == ImageSource.camera) {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        requestFullMetadata: true,
        maxWidth: 2400,
      );
      files = x == null ? const [] : [x];
    } else {
      files = await _picker.pickMultiImage(requestFullMetadata: true, maxWidth: 2400);
    }
    final out = <PendingPhoto>[];
    for (final f in files.take(remainingSlots)) {
      final bytes = await f.readAsBytes();
      if (bytes.length > maxPhotoBytes) continue;
      final exif = await _readExif(bytes);
      out.add(PendingPhoto(
        bytes: bytes,
        contentType: f.mimeType ?? 'image/jpeg',
        exifLat: exif.lat,
        exifLng: exif.lng,
        takenAt: exif.takenAt,
      ));
    }
    return out;
  }

  /// Submits a "missing postbox" report. Returns the new report id.
  static Future<String> submitMissingPostbox({
    required double lat,
    required double lng,
    double? accuracyMeters,
    String? note,
    String? suggestedMonarch, // null = not provided; [plainCypher] = plain; else a cypher key
    String? suggestedReference,
    List<PendingPhoto> photos = const [],
  }) async {
    final uploaded = await _uploadPhotos(photos);
    final data = <String, dynamic>{
      'type': 'missing_postbox',
      'lat': lat,
      'lng': lng,
      if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
      ..._optionalFields(note, suggestedMonarch, suggestedReference),
      'photos': uploaded,
    };
    return _callAndCleanup(data, uploaded);
  }

  /// Submits a "wrong / missing cypher" report against an existing postbox.
  static Future<String> submitWrongCypher({
    required String postboxId,
    String? note,
    String? suggestedMonarch, // null = not provided; [plainCypher] = plain; else a cypher key
    String? suggestedReference,
    List<PendingPhoto> photos = const [],
  }) async {
    final uploaded = await _uploadPhotos(photos);
    final data = <String, dynamic>{
      'type': 'wrong_cypher',
      'postboxId': postboxId,
      ..._optionalFields(note, suggestedMonarch, suggestedReference),
      'photos': uploaded,
    };
    return _callAndCleanup(data, uploaded);
  }

  // ── internals ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _optionalFields(
    String? note,
    String? suggestedMonarch,
    String? suggestedReference,
  ) {
    final m = <String, dynamic>{};
    final n = note?.trim();
    if (n != null && n.isNotEmpty) m['note'] = n;
    final r = suggestedReference?.trim();
    if (r != null && r.isNotEmpty) m['suggestedReference'] = r;
    if (suggestedMonarch != null) {
      m['suggestedMonarch'] = suggestedMonarch == plainCypher ? null : suggestedMonarch;
    }
    return m;
  }

  static Future<List<Map<String, dynamic>>> _uploadPhotos(List<PendingPhoto> photos) async {
    if (photos.isEmpty) return const [];
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('You must be signed in to attach photos.');
    final storage = FirebaseStorage.instance;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final result = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < photos.length && i < maxPhotos; i++) {
        final p = photos[i];
        final ext = p.contentType.contains('png') ? 'png' : 'jpg';
        final path = 'report_photos/$uid/${stamp}_$i.$ext';
        await storage.ref(path).putData(p.bytes, SettableMetadata(contentType: p.contentType));
        result.add({
          'storagePath': path,
          if (p.exifLat != null) 'exifLat': p.exifLat,
          if (p.exifLng != null) 'exifLng': p.exifLng,
          if (p.takenAt != null) 'takenAt': p.takenAt,
        });
      }
    } catch (e) {
      // Mid-upload failure: clean up whatever did make it to Storage so we
      // don't leak orphan files into the user's report_photos/ folder when
      // the report is never submitted.
      unawaited(_deleteUploaded(result));
      rethrow;
    }
    return result;
  }

  /// Submits the report; on failure deletes any photos that were uploaded
  /// during the call so they don't sit in Storage forever attached to a
  /// report doc that never got written.
  static Future<String> _callAndCleanup(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> uploaded,
  ) async {
    try {
      return await _call(data);
    } catch (e) {
      unawaited(_deleteUploaded(uploaded));
      rethrow;
    }
  }

  static Future<String> _call(Map<String, dynamic> data) async {
    final result = await FirebaseFunctions.instance.httpsCallable('submitReport').call(data);
    final map = Map<String, dynamic>.from(result.data as Map);
    return map['reportId'] as String? ?? '';
  }

  static Future<void> _deleteUploaded(List<Map<String, dynamic>> uploaded) async {
    if (uploaded.isEmpty) return;
    final storage = FirebaseStorage.instance;
    await Future.wait(uploaded.map((p) async {
      final path = p['storagePath'];
      if (path is! String || path.isEmpty) return;
      try {
        await storage.ref(path).delete();
      } catch (_) {
        // Best-effort cleanup — a failure here is preferable to surfacing
        // a "report failed AND cleanup failed" double error to the user.
      }
    }));
  }

  /// Extracts GPS coordinates and capture time from a JPEG's EXIF. Any field
  /// may be null (browsers strip GPS; not all cameras embed it).
  static Future<({double? lat, double? lng, String? takenAt})> _readExif(Uint8List bytes) async {
    try {
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return (lat: null, lng: null, takenAt: null);
      var lat = _dmsToDeg(tags['GPS GPSLatitude'], tags['GPS GPSLatitudeRef']?.printable);
      var lng = _dmsToDeg(tags['GPS GPSLongitude'], tags['GPS GPSLongitudeRef']?.printable);
      if (lat != null && (!lat.isFinite || lat.abs() > 90)) lat = null;
      if (lng != null && (!lng.isFinite || lng.abs() > 180)) lng = null;
      if (lat == null || lng == null) {
        lat = null;
        lng = null;
      }
      String? taken = tags['EXIF DateTimeOriginal']?.printable ?? tags['Image DateTime']?.printable;
      if (taken != null && taken.length > 40) taken = taken.substring(0, 40);
      return (lat: lat, lng: lng, takenAt: taken);
    } catch (_) {
      return (lat: null, lng: null, takenAt: null);
    }
  }

  static double? _dmsToDeg(IfdTag? tag, String? ref) {
    if (tag == null) return null;
    try {
      final values = tag.values.toList();
      if (values.length < 3) return null;
      double comp(dynamic v) {
        if (v is num) return v.toDouble();
        // exif Ratio: has numerator/denominator
        final num n = (v as dynamic).numerator as num;
        final num d = (v as dynamic).denominator as num;
        return d == 0 ? 0 : n / d;
      }
      final deg = comp(values[0]) + comp(values[1]) / 60.0 + comp(values[2]) / 3600.0;
      final r = (ref ?? '').toUpperCase();
      return (r == 'S' || r == 'W') ? -deg : deg;
    } catch (_) {
      return null;
    }
  }
}
