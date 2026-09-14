import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class RecordedVideoDialog extends StatelessWidget {
  final XFile videoFile;
  final Duration duration;
  final bool savedToGallery;

  const RecordedVideoDialog({
    super.key,
    required this.videoFile,
    required this.duration,
    this.savedToGallery = false,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.greenAccent, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tr('PrompterScreen.Camera_VideoSaved'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${context.tr("PrompterScreen.Camera_Duration")}: ${_formatDuration(duration)}',
            style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                savedToGallery ? Icons.photo_library : Icons.warning_amber_rounded,
                color: savedToGallery ? Colors.greenAccent : Colors.orangeAccent,
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  savedToGallery
                      ? context.tr('PrompterScreen.Camera_SavedToGallery')
                      : context.tr('PrompterScreen.Camera_NotSavedToGallery'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          // The cache path is only useful while the file is not in the gallery.
          if (!savedToGallery) ...[
            const SizedBox(height: 8),
            Text(
              videoFile.path,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('PrompterScreen.Camera_Close')),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.share),
          label: Text(context.tr('PrompterScreen.Camera_ShareVideo')),
          onPressed: () async {
            await SharePlus.instance.share(
              ShareParams(
                files: [videoFile],
                text: 'Vidéo enregistrée avec TiefPrompt',
              ),
            );
          },
        ),
      ],
    );
  }
}
