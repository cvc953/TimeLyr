import '../models/song.dart';
import '../services/lrclib_service.dart';
import 'file_service.dart';
import '../models/lyric_result.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

enum LyricsFetchFailure { notFound, network }

class LyricsFetchResult {
  final String? lyrics;
  final LyricsFetchFailure? failure;
  final String? message;

  const LyricsFetchResult._({this.lyrics, this.failure, this.message});

  bool get isSuccess => lyrics != null;

  static LyricsFetchResult success(String lyrics) =>
      LyricsFetchResult._(lyrics: lyrics);

  static LyricsFetchResult notFound() =>
      const LyricsFetchResult._(failure: LyricsFetchFailure.notFound);

  static LyricsFetchResult network(String message) =>
      LyricsFetchResult._(failure: LyricsFetchFailure.network, message: message);
}

class LyricsSaveResult {
  final bool saved;
  final LyricsFetchFailure? failure;
  final String? message;

  const LyricsSaveResult._({
    required this.saved,
    this.failure,
    this.message,
  });

  static LyricsSaveResult success() => const LyricsSaveResult._(saved: true);

  static LyricsSaveResult notFound() =>
      const LyricsSaveResult._(saved: false, failure: LyricsFetchFailure.notFound);

  static LyricsSaveResult network(String message) => LyricsSaveResult._(
    saved: false,
    failure: LyricsFetchFailure.network,
    message: message,
  );
}

class LyricsService {
  /// Devuelve la letra ideal:
  /// - syncedLyrics (si disponible)
  /// - sino plainLyrics
  /// - sino null
  static Future<String?> fetchLyrics(Song song) async {
    final result = await fetchLyricsResult(song);
    return result.lyrics;
  }

  static Future<LyricsFetchResult> fetchLyricsResult(Song song) async {
    try {
      // Llamada a LRCLib
      final result = await LRCLibService.getLyrics(
        artist: song.artist,
        title: song.title,
        album: song.album,
        durationSeconds: song.durationSeconds,
      );

      if (result == null) {
        return LyricsFetchResult.notFound();
      }

      // Preferir syncedLyrics
      if (result.syncedLyrics.isNotEmpty &&
          result.syncedLyrics.trim().isNotEmpty) {
        return LyricsFetchResult.success(result.syncedLyrics.trim());
      }

      // Si no hay synced, usar plainLyrics
      if (result.plainLyrics.isNotEmpty &&
          result.plainLyrics.trim().isNotEmpty) {
        return LyricsFetchResult.success(result.plainLyrics.trim());
      }

      if (result.isInstrumental == true &&
          result.plainLyrics.isEmpty &&
          result.syncedLyrics.isEmpty) {
        return LyricsFetchResult.success(
          "[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n[Instrumental]\n[by:TimeLyr]\n[source:LRCLib.net]",
        );
      }

      return LyricsFetchResult.notFound();
    } on LRCLibNetworkException catch (e) {
      return LyricsFetchResult.network(e.message);
    } catch (_) {
      return LyricsFetchResult.network(
        "Error técnico al consultar letras. Probá de nuevo.",
      );
    }
  }

  /// Descarga y guarda en archivo .lrc
  static Future<bool> downloadAndSave(Song song) async {
    final saveResult = await downloadAndSaveResult(song);
    return saveResult.saved;
  }

  static Future<LyricsSaveResult> downloadAndSaveResult(Song song) async {
    final fetchResult = await fetchLyricsResult(song);
    final lyrics = fetchResult.lyrics;

    // Si LRCLib no encontró (no es error de red), hacer fallback a Kpoe
    if (lyrics == null && fetchResult.failure != LyricsFetchFailure.network) {
      final ttmlSaved = await FileService.saveTTMLForSong(song.path, song);
      if (ttmlSaved) {
        return LyricsSaveResult.success();
      }
      // También pudo haber salvado LRC como fallback del TTML
      final file = File(song.path);
      final lrcFile = File(
        "${file.parent.path}/${p.basenameWithoutExtension(file.path)}.lrc",
      );
      if (await lrcFile.exists()) {
        return LyricsSaveResult.success();
      }
    }

    if (lyrics == null) {
      if (fetchResult.failure == LyricsFetchFailure.network) {
        return LyricsSaveResult.network(
          fetchResult.message ??
              "Error técnico al consultar letras. Probá de nuevo.",
        );
      }
      return LyricsSaveResult.notFound();
    }

    await FileService.saveLRC(song.path, lyrics, song);
    // Intentar también descargar y guardar el TTML desde Lyrics+ junto al archivo
    try {
      await FileService.saveTTMLForSong(song.path, song);
    } catch (_) {}
    return LyricsSaveResult.success();
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
