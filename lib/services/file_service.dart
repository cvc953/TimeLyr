import 'dart:io';
import 'dart:isolate';
import 'package:timelyr/utils/artwork_cache.dart';
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
  static Future<void> _processingLock =
      Future.value(); // For sequential processing

  static void setLibrarySongs(List<Song> songs) {
    librarySongs = songs;
    indexedPaths = songs.map((s) => s.path).toSet();
  }

  // Ajustable para controlar paralelismo durante el escaneo
  static int scanConcurrency = 6;
  // Stream para notificar cambios en la librería (añadidos/actualizaciones)
  static final StreamController<void> libraryUpdateController =
      StreamController<void>.broadcast();

  // Background scan isolate
  static Isolate? _scanIsolate;
  static ReceivePort? _receivePort;
  static StreamSubscription? _receivePortSubscription;
  static SendPort? _scanSendPort;

  static Future<void> scanMusicWithCallback(
    String rootPath, {
    required Function(String path, int scanned, int found) onScan,
  }) async {
    // Usar MediaStore para escanear música rápidamente
    final List<dynamic> musicList = await MetadataReader.scanMusic();

    List<Song> songs = [];
    final cached = await SongDatabase.load();
    final Map<String, Song> cachedByPath = {for (var s in cached) s.path: s};

    for (int i = 0; i < musicList.length; i++) {
      final item = musicList[i] as Map<dynamic, dynamic>;
      final path = item['path'] as String?;

      if (path == null) continue;

      onScan(path, i + 1, songs.length);

      // Si ya existe en caché, reutilizar la entrada
      if (cachedByPath.containsKey(path)) {
        songs.add(cachedByPath[path]!);
        continue;
      }

      final song = Song(
        path: path,
        title: item['title'] as String? ?? path.split('/').last,
        artist: item['artist'] as String? ?? '',
        album: item['album'] as String? ?? '',
        durationSeconds: ((item['durationMs'] as num?)?.toInt() ?? 0) ~/ 1000,
        modifiedMs: DateTime.now().millisecondsSinceEpoch,
        size: 0,
      );

      songs.add(song);
    }

    setLibrarySongs(songs);
    await SongDatabase.save(songs);
    libraryUpdateController.add(null);
  }

  /// Procesa un único archivo de audio e intenta añadirlo a la librería.
  static Future<Song?> processSingleFile(String path) async {
    try {
      // Si ya está indexado, no hacer nada (O(1) lookup)
      if (indexedPaths.contains(path)) return null;

      final metadata = await MetadataReader.getMetadata(path);

      if (metadata == null) return null;

      final artwork = metadata['artwork'];
      if (artwork != null && artwork is Uint8List) {
        ArtworkCache.save(path, artwork);
      }

      final song = Song(
        path: path,
        title: metadata['title'] as String? ?? path.split('/').last,
        artist: metadata['artist'] as String? ?? '',
        album: metadata['album'] as String? ?? '',
        durationSeconds:
            ((metadata['durationMs'] as num?)?.toInt() ?? 0) ~/ 1000,
        modifiedMs: DateTime.now().millisecondsSinceEpoch,
        size: 0,
      );

      // Ensure sequential processing (already handled by listener)
      librarySongs.add(song);
      indexedPaths.add(path);

      // Guardar inmediatamente la base actualizada
      await SongDatabase.save(librarySongs);

      // Notificar a la UI que la librería cambió
      libraryUpdateController.add(null);

      return song;
    } catch (_) {
      return null;
    }
  }

  /// Inicia un watcher en segundo plano que detecta archivos nuevos/modificados.
  static Future<void> startBackgroundWatcher(String rootPath) async {
    try {
      stopBackgroundWatcher();

      _receivePort = ReceivePort();
      _receivePortSubscription = _receivePort?.listen((message) {
        if (message is SendPort) {
          _scanSendPort = message;
          // Send the root path to the isolate
          _scanSendPort?.send(rootPath);
        } else if (message is String) {
          // Process new/modified file sequentially
          _processingLock = _processingLock.then((_) async {
            await processSingleFile(message);
          });
        }
      });

      _scanIsolate = await Isolate.spawn(
        _backgroundScanIsolate,
        _receivePort!.sendPort,
      );
    } catch (_) {}
  }

  static void _backgroundScanIsolate(SendPort sendPort) {
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    String? rootPath;
    final completer = Completer<void>();

    receivePort.listen((message) {
      if (message is String) {
        rootPath = message;
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });

    final sentFiles = <String>[];

    void performScan() {
      if (rootPath == null) return;

      try {
        final dir = Directory(rootPath!);
        final files = dir.listSync(recursive: true);

        for (var entity in files) {
          if (entity is File &&
              (entity.path.endsWith('.mp3') ||
                  entity.path.endsWith('.flac') ||
                  entity.path.endsWith('.m4a') ||
                  entity.path.endsWith('.wav'))) {
            if (!sentFiles.contains(entity.path)) {
              sentFiles.add(entity.path);
              sendPort.send(entity.path);
            }
          }
        }
      } catch (_) {}
    }

    completer.future.then((_) {
      performScan();

      Timer.periodic(const Duration(seconds: 30), (timer) {
        performScan();
      });
    });
  }

  static void stopBackgroundWatcher() {
    try {
      _scanIsolate?.kill(priority: Isolate.immediate);
      _scanIsolate = null;
      _receivePortSubscription?.cancel();
      _receivePortSubscription = null;
      _receivePort?.close();
      _receivePort = null;
      _scanSendPort = null;
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
