import 'dart:io';
import 'package:timelyr/utils/artwork_cache.dart';
import 'package:timelyr/utils/song_database.dart';
import 'package:metadata_god/metadata_god.dart';
import '../models/song.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:timelyr/services/kpoe_remote_service.dart';

class FileService {
  static List<Song> librarySongs = [];

  static Future<void> scanMusicWithCallback(
    String rootPath, {
    required Function(String path, int scanned, int found) onScan,
  }) async {
    final dir = Directory(rootPath);
    List<Song> songs = [];

    int scanned = 0;

    await for (var entity in dir.list(recursive: true)) {
      scanned++;

      onScan(entity.path, scanned, songs.length);

      //print("Leyendo: ${entity.path}");

      if (entity is File &&
          (entity.path.endsWith(".mp3") ||
              entity.path.endsWith(".flac") ||
              entity.path.endsWith(".m4a") ||
              entity.path.endsWith(".wav"))) {
        try {
          final metadata = await MetadataGod.readMetadata(file: entity.path);

          //final art = metadata.picture?.data;

          if (metadata.picture?.data != null) {
            ArtworkCache.save(entity.path, metadata.picture!.data);
          }

          songs.add(
            Song(
              path: entity.path,
              title:
                  metadata.title ??
                  entity.uri.pathSegments.last.replaceAll(
                    RegExp(r'\.(mp3|flac|m4a|wav)$'),
                    '',
                  ),
              artist: metadata.artist ?? "",
              album: metadata.album ?? "",
              durationSeconds: (metadata.durationMs ?? 0) ~/ 1000,
            ),
          );
        } catch (_) {}
      }
    }

    librarySongs = songs;
    await SongDatabase.save(songs);
    //final art = await ArtworkCache.load(songs[0].path);
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
        // Normalize the response into a proper TTML string. The server may
        // return raw TTML, a JSON envelope with `ttml`, or a KPoe-style JSON
        // structure. Use the shared converter to produce clean TTML.
        String ttmlContent = KpoeRemoteService.convertKpoeJsonToTtml(res.body);

        // Redundantly normalize/format again before writing to disk to ensure
        // timestamps, XML declaration and spacing are correct.
        ttmlContent = KpoeRemoteService.convertKpoeJsonToTtml(ttmlContent);

        final ttmlFile = File(ttmlPath);
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
