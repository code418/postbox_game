import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/reports/report_repository.dart';
import 'package:postbox_game/theme.dart';

/// Sentinel returned by [CypherPicker] for "I'm not sure" — the caller should
/// omit the suggested cypher from the report. [plainCypher] (from
/// report_repository.dart) means "the box has no cypher".
const String notSureCypher = '__NOT_SURE__';

/// Dropdown over the known royal cyphers plus "Plain / no cypher" and
/// "I'm not sure". The selected value is one of: [notSureCypher],
/// [plainCypher], or a key from [MonarchInfo.labels].
class CypherPicker extends StatelessWidget {
  const CypherPicker({super.key, required this.value, required this.onChanged, this.label});

  final String value;
  final ValueChanged<String> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label ?? 'Correct cypher',
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: notSureCypher, child: Text("I'm not sure")),
        const DropdownMenuItem(value: plainCypher, child: Text('Plain / no cypher')),
        for (final key in MonarchInfo.all)
          DropdownMenuItem(value: key, child: Text(MonarchInfo.labels[key] ?? key, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// Lets the user attach up to [ReportRepository.maxPhotos] photos. The list is
/// owned by the parent; this widget renders thumbnails + an "add" tile and
/// calls [onChanged] with the new list.
class PhotoPickerField extends StatelessWidget {
  const PhotoPickerField({super.key, required this.photos, required this.onChanged});

  final List<PendingPhoto> photos;
  final ValueChanged<List<PendingPhoto>> onChanged;

  Future<void> _add(BuildContext context) async {
    final remaining = ReportRepository.maxPhotos - photos.length;
    if (remaining <= 0) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final result = await ReportRepository.pickPhotos(
          source: source, remainingSlots: remaining);
      if (result.photos.isNotEmpty) {
        onChanged([...photos, ...result.photos]
            .take(ReportRepository.maxPhotos)
            .toList());
      }
      if (result.oversizedCount > 0 && context.mounted) {
        final maxMb =
            (ReportRepository.maxPhotoBytes / (1024 * 1024)).toStringAsFixed(0);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.oversizedCount == 1
                ? 'Skipped 1 photo over $maxMb MB.'
                : 'Skipped ${result.oversizedCount} photos over $maxMb MB.'),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not add photo. Please try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Photos (optional)', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Photos taken on a phone with location on help us verify the box. Up to ${ReportRepository.maxPhotos}.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < photos.length; i++) _Thumb(
                photo: photos[i],
                onRemove: () => onChanged([...photos]..removeAt(i)),
              ),
              if (photos.length < ReportRepository.maxPhotos)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: InkWell(
                    onTap: () => _add(context),
                    child: Container(
                      width: 96,
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.outline),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [Icon(Icons.add_a_photo_outlined), SizedBox(height: 4), Text('Add', style: TextStyle(fontSize: 12))],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.photo, required this.onRemove});
  final PendingPhoto photo;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            // cacheWidth/cacheHeight tell Flutter to decode at thumbnail size
            // instead of holding the full ~2400 px source in the image cache.
            // Without this, 3 attached photos can sit at ~15-25 MB of decoded
            // bitmap memory on the picker screen alone.
            child: Image.memory(
              photo.bytes,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
              cacheWidth: 192,
              cacheHeight: 192,
            ),
          ),
          if (photo.hasLocation)
            const Positioned(
              left: 4,
              bottom: 4,
              child: Icon(Icons.location_on, size: 16, color: Colors.white, shadows: [Shadow(blurRadius: 3)]),
            ),
          Positioned(
            right: 0,
            top: 0,
            // Tooltip provides the semantic label so screen readers announce
            // "Remove photo" instead of just "icon button" on TalkBack /
            // VoiceOver, and sighted users see the hint on long-press.
            child: Tooltip(
              message: 'Remove photo',
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  decoration:
                      const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows a "report received" dialog. Used by both report screens on success.
Future<void> showReportThanksDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      icon: const Icon(Icons.check_circle_outline, color: postalRed, size: 40),
      title: const Text('Thanks for the report'),
      content: const Text(
        'Thanks for the report. If it checks out we will '
        'update the data and, where it applies, your past claims will be re-scored.',
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Righto'))],
    ),
  );
}
