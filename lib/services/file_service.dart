import 'dart:io';
import 'package:timelyr/utils/artwork_cache.dart';
import 'package:timelyr/utils/song_database.dart';
import 'package:metadata_god/metadata_god.dart';
import '../models/song.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:timelyr/services/kpoe_remote_service.dart';

class FileService {
  static List<Song> librarySongs = [];
  static StreamSubscription<FileSystemEvent>? _watcher;
  // Ajustable para controlar paralelismo durante el escaneo
  static int scanConcurrency = 6;

  static Future<void> scanMusicWithCallback(
    String rootPath, {
    required Function(String path, int scanned, int found) onScan,
  }) async {
    final dir = Directory(rootPath);
    List<Song> songs = [];

    // Cargar canciones ya guardadas para evitar releer metadata innecesaria
    final cached = await SongDatabase.load();
    final Map<String, Song> cachedByPath = {for (var s in cached) s.path: s};

    // Primero hacer un listado de archivos (rápido) y luego procesar metadata en paralelo
    final List<String> audioPaths = [];
    int scanned = 0;

    await for (var entity in dir.list(recursive: true)) {
      scanned++;
      onScan(entity.path, scanned, songs.length);

      if (entity is File &&
          (entity.path.endsWith('.mp3') ||
              entity.path.endsWith('.flac') ||
              entity.path.endsWith('.m4a') ||
              entity.path.endsWith('.wav'))) {
        audioPaths.add(entity.path);
      }
    }

    // Procesar metadata en lotes para mantener concurrencia limitada
    final int concurrency = scanConcurrency;
    final int total = audioPaths.length;

    for (int i = 0; i < total; i += concurrency) {
      final end = (i + concurrency) > total ? total : i + concurrency;
      final batch = audioPaths.sublist(i, end);

      final futures = batch.map((path) async {
        try {
          final file = File(path);
          final stat = await file.stat();
          final int modifiedMs = stat.modified.millisecondsSinceEpoch;
          final int size = stat.size;

          // Si existe en caché y no ha cambiado, reutilizar
          final cachedSong = cachedByPath[path];
          if (cachedSong != null &&
              (cachedSong.modifiedMs == modifiedMs) &&
              (cachedSong.size == size)) {
            songs.add(cachedSong);
            // Actualizar UI
            onScan(path, scanned, songs.length);
            return;
          }

          final metadata = await MetadataGod.readMetadata(file: path);

          if (metadata.picture?.data != null) {
            ArtworkCache.save(path, metadata.picture!.data);
          }

          final song = Song(
            path: path,
            title: metadata.title ??
                file.uri.pathSegments.last.replaceAll(
                  RegExp(r'\.(mp3|flac|m4a|wav)$'),
                  '',
                ),
            artist: metadata.artist ?? '',
            album: metadata.album ?? '',
            durationSeconds: (metadata.durationMs ?? 0) ~/ 1000,
            modifiedMs: modifiedMs,
            size: size,
          );

          songs.add(song);
          onScan(path, scanned, songs.length);
        } catch (_) {}
      }).toList();

      try {
        await Future.wait(futures);
      } catch (_) {}
    }

    librarySongs = songs;
    await SongDatabase.save(songs);
  }

  /// Procesa un único archivo de audio e intenta añadirlo a la librería.
  static Future<Song?> processSingleFile(String path) async {
    try {
      final file = File(path);

      if (!file.existsSync()) return null;

      if (!(path.endsWith('.mp3') ||
          path.endsWith('.flac') ||
          path.endsWith('.m4a') ||
          path.endsWith('.wav'))) return null;

      // Si ya está indexado, no hacer nada
      if (librarySongs.any((s) => s.path == path)) return null;

      // Dar pequeño retraso para archivos que aún se estén escribiendo
      await Future.delayed(const Duration(milliseconds: 350));

      final metadata = await MetadataGod.readMetadata(file: path);

      if (metadata.picture?.data != null) {
        ArtworkCache.save(path, metadata.picture!.data);
      }

      final stat = await file.stat();
      final song = Song(
        path: path,
        title: metadata.title ?? file.uri.pathSegments.last.replaceAll(RegExp(r'\.(mp3|flac|m4a|wav)$'), ''),
        artist: metadata.artist ?? '',
        album: metadata.album ?? '',
        durationSeconds: (metadata.durationMs ?? 0) ~/ 1000,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );

      librarySongs.add(song);

      // Guardar inmediatamente la base actualizada
      await SongDatabase.save(librarySongs);

      return song;
    } catch (_) {
      return null;
    }
  }

  /// Inicia un watcher en segundo plano que detecta archivos nuevos/modificados.
  static void startBackgroundWatcher(String rootPath) {
    try {
      stopBackgroundWatcher();
      final dir = Directory(rootPath);
      _watcher = dir.watch(recursive: true).listen((event) async {
        if (event is FileSystemCreateEvent || event is FileSystemModifyEvent) {
          final evtPath = event.path;
          if (evtPath.endsWith('.mp3') || evtPath.endsWith('.flac') || evtPath.endsWith('.m4a') || evtPath.endsWith('.wav')) {
            await processSingleFile(evtPath);
          }
        }
      });
    } catch (_) {}
  }

  static void stopBackgroundWatcher() {
    try {
      _watcher?.cancel();
      _watcher = null;
    } catch (_) {}
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

  static String lyricsPlusUrlForSong(Song song) {
    final params = {
      'title': song.title ?? '',
      'artist': song.artist ?? '',
      'album': song.album ?? '',
      'duration': (song.durationSeconds ?? 0).toString(),
    };

    final uri = Uri.https(
      'lyricsplus-seven.vercel.app',
      '/v1/ttml/get',
      params,
    );

    return uri.toString();
  }

  /// Descarga el TTML desde la URL dada y lo guarda junto al archivo de la canción
  /// con la misma base de nombre y extensión `.ttml`.
  static Future<bool> saveTTMLFromUrl(String songPath, String url) async {
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

      final res = await http.get(Uri.parse(url));

      if (res.statusCode == 200) {
        // Usar solo una vez el convertidor para asegurar formato correcto.
        String ttmlContent = KpoeRemoteService.convertKpoeJsonToTtml(res.body);

        // No guardar si algún <p> no tiene <span> ni </span>
        if (KpoeRemoteService.hasParagraphWithoutAnySpan(ttmlContent)) {
          return false;
        }

        final ttmlFile = File(ttmlPath);
        // Añadir espacio a las palabras cuando hay separación entre spans
        ttmlContent = KpoeRemoteService.agregarEspacioEntreSpans(ttmlContent);
        await ttmlFile.writeAsString(ttmlContent);
        return true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  /// Construye la URL para `lyricsplus` y descarga/guarda el TTML para la canción.
  static Future<bool> saveTTMLForSong(String songPath, Song song) async {
    final url = lyricsPlusUrlForSong(song);
    return await saveTTMLFromUrl(songPath, url);
  }

  static Future<Uint8List?> loadArtwork(String path) async {
    try {
      final meta = await MetadataGod.readMetadata(file: path);
      return meta.picture?.data;
    } catch (_) {
      return null;
    }
  }
}
