import 'dart:io';
import 'package:timelyr/utils/song_database.dart';
import 'package:timelyr/services/metadata_reader.dart';
import '../models/song.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:timelyr/services/kpoe_remote_service.dart';
import 'package:timelyr/services/lrc_red_service.dart';

class FileService {
  static List<Song> librarySongs = [];
  static Set<String> indexedPaths = {}; // For O(1) lookups
  static int _activeScanId = 0;

  static void cancelActiveScan() {
    _activeScanId++;
  }

  static void setLibrarySongs(List<Song> songs) {
    librarySongs = songs;
    indexedPaths = songs.map((s) => s.path).toSet();
  }

  // Stream para notificar cambios en la librería (añadidos/actualizaciones)
  static final StreamController<void> libraryUpdateController =
      StreamController<void>.broadcast();

  static Future<void> scanMusicWithCallback(
    String rootPath, {
    required Function(String path, int scanned, int found) onScan,
  }) async {
    final int scanId = ++_activeScanId;
    final normalizedRoot = p.normalize(rootPath);

    // Usar MediaStore para escanear música rápidamente
    final List<dynamic> musicList = await MetadataReader.scanMusic(
      rootPath: normalizedRoot,
    );

    if (scanId != _activeScanId) {
      return;
    }

    List<Song> songs = [];
    final cached = await SongDatabase.load();
    final Map<String, Song> cachedByPath = {
      for (var s in cached) p.normalize(s.path): s,
    };

    for (int i = 0; i < musicList.length; i++) {
      if (scanId != _activeScanId) {
        return;
      }

      if (i % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      final item = musicList[i] as Map<dynamic, dynamic>;
      final path = item['path'] as String?;

      if (path == null) continue;

      final normalizedPath = p.normalize(path);
      if (!p.isWithin(normalizedRoot, normalizedPath) &&
          normalizedPath != normalizedRoot) {
        continue;
      }

      // Si ya existe en caché, reutilizar la entrada
      if (cachedByPath.containsKey(normalizedPath)) {
        songs.add(cachedByPath[normalizedPath]!);
        onScan(path, i + 1, songs.length);
        continue;
      }

      final song = Song(
        path: normalizedPath,
        title: item['title'] as String? ?? normalizedPath.split('/').last,
        artist: item['artist'] as String? ?? '',
        album: item['album'] as String? ?? '',
        durationSeconds: ((item['durationMs'] as num?)?.toInt() ?? 0) ~/ 1000,
        modifiedMs: DateTime.now().millisecondsSinceEpoch,
        size: 0,
      );

      songs.add(song);
      onScan(path, i + 1, songs.length);
    }

    if (scanId != _activeScanId) {
      return;
    }

    setLibrarySongs(songs);
    await SongDatabase.save(songs);
    libraryUpdateController.add(null);
  }

  static String _ttmlPathFor(String songPath) {
    final file = File(songPath);
    final dir = file.parent.path;
    final filename = p.basenameWithoutExtension(file.path);
    return "$dir/$filename.ttml";
  }

  static String _lrcPathFor(String songPath) {
    final file = File(songPath);
    final dir = file.parent.path;
    final filename = p.basenameWithoutExtension(file.path);
    return "$dir/$filename.lrc";
  }

  static bool _isValidTtml(String contents) {
    if (!contents.contains('<tt') && !contents.contains('<?xml')) {
      return false;
    }
    return contents.trim().length > 100;
  }

  static Future<bool> _hasValidTtml(String songPath) async {
    final ttmlFile = File(_ttmlPathFor(songPath));
    if (!ttmlFile.existsSync()) return false;
    try {
      return _isValidTtml(await ttmlFile.readAsString());
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveLRC(
    String songPath,
    String lyrics,
    Song song, {
    String source = 'LRCLib.net',
  }) async {
    final lrcFile = File(_lrcPathFor(songPath));
    await lrcFile.writeAsString(
      '$lyrics\n[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n\n[by:TimeLyr]\n[source:$source]',
    );
  }

  static Future<void> _saveTtmlAsLrcFallback(
    String songPath,
    Song song,
    String ttmlContent, {
    String source = 'Lyrics+',
  }) async {
    final lrcLyrics = KpoeRemoteService.convertTtmlToLrc(ttmlContent);
    if (lrcLyrics.trim().isEmpty) return;

    // No guardar si todos los timestamps son 00:00.00 (fuente sin timing real)
    final tsRe = RegExp(r'^\[(\d{2}:\d{2}\.\d{2})\]');
    final tsLines =
        lrcLyrics.split('\n').where((l) => tsRe.hasMatch(l)).toList();
    if (tsLines.isNotEmpty && tsLines.every((l) => l.startsWith('[00:00.00]'))) {
      return;
    }

    await saveLRC(songPath, lrcLyrics, song, source: source);
  }

  static Future<void> _saveLrcFromTtmlIfMissing(
    String songPath,
    Song song,
    String ttml, {
    required String source,
  }) async {
    if (File(_lrcPathFor(songPath)).existsSync()) return;
    await _saveTtmlAsLrcFallback(songPath, song, ttml, source: source);
  }

  static Future<bool> _saveTTMLContent(
    String songPath,
    Song song,
    String ttmlContent, {
    bool requireSpans = true,
    bool addSpanSpaces = true,
    String source = 'Lyrics+',
  }) async {
    try {
      final ttmlPath = _ttmlPathFor(songPath);

      // Si ya existe un .ttml para esta canción, comprobar su integridad.
      // Si parece válido, no reintentar; si parece dañado, proceder a descargar.
      final existing = File(ttmlPath);
      if (existing.existsSync()) {
        try {
          if (_isValidTtml(await existing.readAsString())) return true;
          // Si no parece válido, continuar y reintentar la descarga (sobrescribir).
        } catch (_) {
          // Si no se puede leer, intentar descargar de nuevo.
        }
      }

      // No guardar como TTML si algún <p> no tiene <span> ni </span>.
      // En ese caso, hacer fallback a LRC para no perder la letra.
      if (requireSpans &&
          KpoeRemoteService.hasParagraphWithoutAnySpan(ttmlContent)) {
        await _saveTtmlAsLrcFallback(
          songPath,
          song,
          ttmlContent,
          source: source,
        );
        return false;
      }

      final ttmlFile = File(ttmlPath);
      // Añadir espacio a las palabras cuando hay separación entre spans.
      final normalized = addSpanSpaces
          ? KpoeRemoteService.agregarEspacioEntreSpans(ttmlContent)
          : ttmlContent;
      await ttmlFile.writeAsString(normalized);
      return true;
    } catch (e) {
      // Log error for debugging
      print('Error saving TTML: $e');
      return false;
    }
  }

  static Future<void> _deriveLrcFromExistingTtmlIfMissing(
    String songPath,
    Song song,
  ) async {
    try {
      final existing = await File(_ttmlPathFor(songPath)).readAsString();
      await _saveLrcFromTtmlIfMissing(
        songPath,
        song,
        existing,
        source: 'TTML',
      );
    } catch (e) {
      print('TTML LRC error: $e');
    }
  }

  static Future<bool> saveTTMLForSong(String songPath, Song song) async {
    // Si ya hay un TTML válido, no hacer peticiones de red. Pero si falta el
    // LRC, derivarlo para que el visualizador pueda mostrar la letra.
    if (await _hasValidTtml(songPath)) {
      await _deriveLrcFromExistingTtmlIfMissing(songPath, song);
      return true;
    }

    // lrc.red es la fuente preferida de TTML.
    try {
      final lrcRedTtml = await LrcRedService.fetchTtmlForSong(
        title: song.title,
        artist: song.artist,
        album: song.album,
        durationSeconds: song.durationSeconds,
      );

      if (lrcRedTtml != null && lrcRedTtml.trim().isNotEmpty) {
        final normalized = KpoeRemoteService.normalizeTtml(lrcRedTtml);
        final saved = await _saveTTMLContent(
          songPath,
          song,
          normalized,
          requireSpans: false,
          addSpanSpaces: true,
          source: 'lrc.red',
        );
        if (saved) {
          try {
            await _saveLrcFromTtmlIfMissing(
              songPath,
              song,
              normalized,
              source: 'lrc.red',
            );
          } catch (e) {
            print('lrc.red LRC error: $e');
          }
          return true;
        }
      }
    } catch (e) {
      print('lrc.red TTML error: $e');
    }

    // Fallback: Lyrics+ (KPoE).
    final ttml = await KpoeRemoteService.fetchFromKpoe(
      song.title,
      song.artist,
      album: song.album,
      duration: song.durationSeconds <= 0
          ? ''
          : song.durationSeconds.toString(),
    );

    if (ttml == null || ttml.trim().isEmpty) {
      return false;
    }

    final converted = KpoeRemoteService.convertKpoeJsonToTtml(
      ttml,
      title: song.title,
      artist: song.artist,
    );

    final saved = await _saveTTMLContent(songPath, song, converted);
    if (saved) {
      try {
        await _saveLrcFromTtmlIfMissing(
          songPath,
          song,
          converted,
          source: 'Lyrics+',
        );
      } catch (e) {
        print('Lyrics+ LRC error: $e');
      }
    }
    return saved;
  }

  static Future<Uint8List?> loadArtwork(String path) async {
    try {
      final meta = await MetadataReader.getMetadata(path);
      return meta?['artwork'] as Uint8List?;
    } catch (_) {
      return null;
    }
  }
}
