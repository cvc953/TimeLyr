import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:timelyr/screens/search_screen.dart';
import 'package:timelyr/utils/artwork_cache.dart';
import '../models/song.dart';
import '../services/lyrics_service.dart';
import '../services/file_service.dart';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

class LyricsViewer extends StatefulWidget {
  final Song song;

  const LyricsViewer({super.key, required this.song});

  @override
  State<LyricsViewer> createState() => _LyricsViewerState();
}

class _LyricsViewerState extends State<LyricsViewer> {
  String? lyrics;
  bool loading = true;
  bool downloading = false;
  Uint8List? artwork;
  bool noLyricsFound = false;

  @override
  void initState() {
    super.initState();
    loadLyrics();
  }

  Future<void> loadLyrics() async {
    // Ver si ya existe archivo LRC
    final file = File(widget.song.path);
    final filename = p.basenameWithoutExtension(file.path);
    final lrcPath = "${file.parent.path}/$filename.lrc";

    if (File(lrcPath).existsSync()) {
      lyrics = await File(lrcPath).readAsString();
      // Intento de guardar/actualizar también el TTML desde Lyrics+
      try {
        FileService.saveTTMLForSong(widget.song.path, widget.song);
      } catch (_) {}

      setState(() => loading = false);
      return;
    }

    // Si no existe → intentar descargar
    final result = await LyricsService.fetchLyrics(widget.song);

    lyrics = result;
    setState(() => loading = false);
  }

  Future<void> downloadLyrics() async {
    setState(() => downloading = true);

    final ok = await LyricsService.downloadAndSave(widget.song);

    if (ok) {
      await loadLyrics();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Letra descargada.")));
    } else {
      setState(() => noLyricsFound = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("No se encontró letra.")));
    }

    setState(() => downloading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Fondo con blur
          Container(
            decoration: BoxDecoration(
              image: artwork != null
                  ? DecorationImage(
                      image: MemoryImage(artwork!),
                      fit: BoxFit.cover,
                      opacity: 0.35,
                    )
                  : null,
              gradient: const LinearGradient(
                colors: [Color(0xFF0D1B2A), Color(0xFF1B263B)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),

          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: Container(color: Colors.black.withValues(alpha: 0.4)),
          ),

          // Contenido principal
          SafeArea(
            child: Column(
              children: [
                // Flecha atrás
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(width: 25),
                    Hero(
                      tag: widget.song.path,
                      child: FutureBuilder<Uint8List?>(
                        future: ArtworkCache.load(widget.song.path),
                        builder: (context, snapshot) {
                          final art = snapshot.data;

                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white70,
                                ),
                              ),
                            );
                          }
                          if (art != null) {
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: Image.memory(
                                art,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                              ),
                            );
                          }
                          return Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white70,
                              size: 80,
                            ),
                          );
                        },
                      ),
                    ),

                    SizedBox(width: 15),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.song.title,
                            textAlign: TextAlign.left,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),

                          // Artista
                          Text(
                            widget.song.artist,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white70,
                            ),
                          ),
                          Text(
                            widget.song.album,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                          Text(
                            "${widget.song.durationSeconds ~/ 60}:${(widget.song.durationSeconds % 60).toString().padLeft(2, '0')} min",
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Titulo
                  ],
                ),

                const SizedBox(height: 15),

                // Botón descagar letra si no existe LRC
                downloading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : //noLyricsFound,
                      ElevatedButton.icon(
                        onPressed: () async {
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SearchScreen(
                                initialTitle: widget.song.title,
                                initialAlbum: widget.song.album,
                                initialArtist: widget.song.artist,
                                song: widget.song,
                              ),
                            ),
                          );
                          if (result != null) {
                            await LyricsService.saveManualResult(
                              widget.song,
                              result,
                            );
                            await loadLyrics();
                          }
                        },
                        icon: const Icon(Icons.search, color: Colors.white),
                        label: const Text(
                          "Buscar letra manualmente",
                          style: TextStyle(color: Colors.white),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                        ),
                      ),

                const SizedBox(height: 15),

                // Letra
                Expanded(
                  child: loading
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        )
                      : lyrics == null
                      ? const Center(
                          child: Text(
                            "No hay letra disponible",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            lyrics!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              height: 1.5,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
