import '../models/song.dart';
import '../services/lrclib_service.dart';
import 'file_service.dart';
import '../models/lyric_result.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

class LyricsService {
  /// Devuelve la letra ideal:
  /// - syncedLyrics (si disponible)
  /// - sino plainLyrics
  /// - sino null
  static Future<String?> fetchLyrics(Song song) async {
    try {
      // Llamada a LRCLib
      final result = await LRCLibService.getLyrics(
        artist: song.artist,
        title: song.title,
        album: song.album,
        durationSeconds: song.durationSeconds,
      );

      if (result == null) {
        //print(">>> No se encontró letra para ${song.title}");
        return null;
      }

      // Preferir syncedLyrics
      if (result.syncedLyrics.isNotEmpty &&
          result.syncedLyrics.trim().isNotEmpty) {
        return result.syncedLyrics.trim();
      }

      // Si no hay synced, usar plainLyrics
      if (result.plainLyrics.isNotEmpty &&
          result.plainLyrics.trim().isNotEmpty) {
        return result.plainLyrics.trim();
      }

      if (result.isInstrumental == true &&
          result.plainLyrics.isEmpty &&
          result.syncedLyrics.isEmpty) {
        // print(">>> La canción ${song.title} es instrumental.");
        return "[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n[Instrumental]\n[by:TimeLyr]\n[source:LRCLib.net]";
      }

      return null;
    } catch (e) {
      //print(">>> Error en fetchLyrics: $e");
      return null;
    }
  }

  /// Descarga y guarda en archivo .lrc
  static Future<bool> downloadAndSave(Song song) async {
    bool savedLrc = false;
    final lyrics = await fetchLyrics(song);

    if (lyrics != null) {
      await FileService.saveLRC(song.path, lyrics, song);
      savedLrc = true;
    }

    bool savedTtml = false;
    try {
      savedTtml = await FileService.saveTTMLForSong(song.path, song);
    } catch (_) {
      savedTtml = false;
    }

    return savedLrc || savedTtml;
  }

  static Future<bool> saveManualResult(Song song, LyricResult result) async {
    try {
      final file = File(song.path);
      final filename = p.basenameWithoutExtension(file.path);

      final String lyrics = result.syncedLyrics.isNotEmpty
          ? result.syncedLyrics
          : result.plainLyrics;
      if (lyrics.trim().isEmpty) return false;

      if (result.isInstrumental ==
          true //&&
      //result.syncedLyrics.isEmpty &&
      // result.plainLyrics.isEmpty
      ) {
        //final base = file.uri.pathSegments.last.split('.').first;
        final lrcPath = "${file.parent.path}/$filename.lrc";

        await File(lrcPath).writeAsString(
          "[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n[Instrumental]\n[by:TimeLyr]\n[source:LRCLib.net]",
        );
        return true;
      }
      //obtener la ruta del archivo de la cancion
      final lrcPath = "${file.parent.path}/$filename.lrc";

      //guardar las letras en el archivo .lrc
      final lrcFile = File(lrcPath);
      await lrcFile.writeAsString(
        '$lyrics\n[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n\n[by:TimeLyr]\n[source:LRCLib.net]',
      );
      // También intentar obtener y guardar el TTML desde Lyrics+
      try {
        await FileService.saveTTMLForSong(song.path, song);
      } catch (_) {}
    } catch (e) {
      // print(">>> Error en saveManualResult: $e");
      return false;
    }
    return true;
  }
}
