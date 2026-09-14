import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';

/// Gallery album the recorded videos are copied to.
const recordingsAlbum = 'Souffleur';

/// Copies a recorded video into the device gallery (album [recordingsAlbum]).
///
/// The camera plugin only writes recordings to the app cache, which Android
/// may purge and which no gallery or file manager can see. Returns false on
/// platforms without a gallery; throws when the copy fails or access is denied.
Future<bool> saveVideoToGallery(String path) async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;

  if (!await Gal.hasAccess(toAlbum: true) &&
      !await Gal.requestAccess(toAlbum: true)) {
    throw StateError('accès à la galerie refusé');
  }
  await Gal.putVideo(path, album: recordingsAlbum);
  return true;
}
