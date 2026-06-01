import 'dart:io';
import 'package:timelyr/utils/song_database.dart';
import 'package:timelyr/services/metadata_reader.dart';
import '../models/song.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:timelyr/services/kpoe_remote_service.dart';

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

  static Future<void> saveLRC(String songPath, String lyrics, Song song) async {
    final file = File(songPath);
    final dir = file.parent.path;
    final filename = p.basenameWithoutExtension(file.path);
    final lrcPath = "$dir/$filename.lrc";

    final lrcFile = File(lrcPath);
    await lrcFile.writeAsString(
      '$lyrics\n[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n\n[by:TimeLyr]\n[source:LRCLib.net]',
    );
  }

  static Future<bool> _saveTTMLContent(
    String songPath,
    String ttmlContent,
  ) async {
    try {
      final file = File(songPath);
      final dir = file.parent.path;
      final filename = p.basenameWithoutExtension(file.path);
      final ttmlPath = "$dir/$filename.ttml";

      // Si ya existe un .ttml para esta canción, comprobar su integridad.
      // Si parece válido, no reintentar; si parece dañado, proceder a descargar.
      final existing = File(ttmlPath);
      if (existing.existsSync()) {
        try {
          final contents = await existing.readAsString();
          // Considerar válido si contiene etiqueta <tt y tiene tamaño razonable
          if (contents.contains('<tt') || contents.contains('<?xml')) {
            if (contents.trim().length > 100) return true;
          }
          // Si no parece válido, continuar y reintentar la descarga (sobrescribir).
        } catch (_) {
          // Si no se puede leer, intentar descargar de nuevo.
        }
      }

      // No guardar si algún <p> no tiene <span> ni </span>
      if (KpoeRemoteService.hasParagraphWithoutAnySpan(ttmlContent)) {
        return false;
      }

      final ttmlFile = File(ttmlPath);
      // Añadir espacio a las palabras cuando hay separación entre spans
      final normalized = KpoeRemoteService.agregarEspacioEntreSpans(
        ttmlContent,
      );
      await ttmlFile.writeAsString(normalized);
      return true;
    } catch (e) {
      // Log error for debugging
      print('Error saving TTML: $e');
      return false;
    }
  }

  static Future<bool> saveTTMLForSong(String songPath, Song song) async {
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

    return _saveTTMLContent(songPath, converted);
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
