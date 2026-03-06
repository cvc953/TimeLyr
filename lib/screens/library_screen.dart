import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:timelyr/utils/artwork_cache.dart';
import '../widgets/gradient_background.dart';
import '../services/file_service.dart';
import '../services/lyrics_service.dart';
import '../models/song.dart';
import 'lyrics_viewer.dart';
import 'dart:typed_data';
import '../services/download_manager.dart';
import 'package:path/path.dart' as p;

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Song> allSongs = [];
  List<Song> filteredSongs = [];
  bool downloadingAll = false;
  Set<String> downloadingSongs = {};
  final Map<String, Uint8List?> artworkCache = {};
  final dm = DownloadManager.instance;
  double ttmlProgress = 0.0;

  @override
  void dispose() {
    _librarySub?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    allSongs = FileService.librarySongs;
    filteredSongs = List.from(allSongs);
    filteredSongs.sort((a, b) => a.title.compareTo(b.title));
    loadArtworkCache();
    // Escuchar cambios en la librería (p. ej. watcher en background)
    _librarySub = FileService.libraryUpdateController.stream.listen((_) async {
      allSongs = FileService.librarySongs;
      filteredSongs = List.from(allSongs);
      filteredSongs.sort((a, b) => a.title.compareTo(b.title));
      await loadArtworkCache();
      setState(() {});
    });
  }

  StreamSubscription<void>? _librarySub;

  Future<void> loadArtworkCache() async {
    for (var song in allSongs) {
      final art = await ArtworkCache.load(song.path);
      artworkCache[song.path] = await ArtworkCache.load(song.path);
    }
    setState(() {});
  }

  void filterSongs(String query) {
    query = query.toLowerCase();

    setState(() {
      filteredSongs = allSongs.where((song) {
        return song.title.toLowerCase().contains(query) ||
            song.artist.toLowerCase().contains(query) ||
            song.album.toLowerCase().contains(query);
      }).toList();
    });
  }

  bool hasLrc(Song song) {
    final file = File(song.path);
    final filename = p.basenameWithoutExtension(file.path);
    return File("${file.parent.path}/$filename.lrc").existsSync();
  }

  bool hasTtml(Song song) {
    final file = File(song.path);
    final filename = p.basenameWithoutExtension(file.path);
    return File("${file.parent.path}/$filename.ttml").existsSync();
  }

  Future<void> downloadOne(Song song) async {
    setState(() {
      downloadingSongs.add(song.path);
    });

    final ok = await LyricsService.downloadAndSave(song);

    setState(() {
      downloadingSongs.remove(song.path);
    });

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("No se encontró letra para ${song.title}")),
      );
      return;
    }

    setState(() {}); // refrescar check verde
  }

  Future<void> downloadPool(List<Song> songs, int poolSize) async {
    final pending = List<Song>.from(songs);

    // tareas activas
    final active = <Future>[];

    // contador para actualizar progreso
    int completed = 0;

    Future<void> startTask(Song song) async {
      setState(() {
        downloadingSongs.add(song.path);
      });

      await LyricsService.downloadAndSave(song);

      setState(() {
        downloadingSongs.remove(song.path);
      });

      completed++;

      setState(() {
        dm.progress = completed / songs.length;
      });
    }

    while (pending.isNotEmpty || active.isNotEmpty) {
      // Llenar el pool con máximo poolSize descargas
      while (pending.isNotEmpty && active.length < poolSize) {
        final song = pending.removeAt(0);
        final task = startTask(song);
        active.add(task);

        // Cuando termine → eliminar del pool
        task.whenComplete(() {
          active.remove(task);
        });
      }

      // Esperar 20ms entre ciclos (suave y eficiente)
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> downloadAll() async {
    final listToDownload = filteredSongs.isNotEmpty ? filteredSongs : allSongs;

    // Separar canciones sin LRC (para descargar LRC + TTML) y canciones
    // que ya tienen LRC (para solo intentar descargar/guardar el TTML).
    final listWithoutLrc = listToDownload
        .where((song) => !hasLrc(song))
        .toList();
    final listWithLrc = listToDownload.where((song) => hasLrc(song)).toList();
    // Escuchar progreso
    DownloadManager().progressStream.listen((p) {
      setState(() => dm.progress = p);
    });

    // Progreso TTML
    int ttmlCompleted = 0;
    final totalTtml = filteredSongs.length;

    setState(() {
      downloadingAll = true;
    });

    // Descarga LRC (y TTML) para las canciones que no tienen LRC
    await DownloadManager().downloadAll(listWithoutLrc);

    // Para las canciones que ya tienen LRC, intentar descargar/guardar solo el TTML
    try {
      final futures = listWithLrc.map((s) async {
        final result = await FileService.saveTTMLForSong(s.path, s);
        ttmlCompleted++;
        setState(() {
          ttmlProgress = ttmlCompleted / totalTtml;
        });
        return result;
      });
      await Future.wait(futures);
    } catch (_) {}

    setState(() {
      downloadingAll = false;
      dm.progress = 0;
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Descarga completa.")));
  }

  @override
  Widget build(BuildContext context) {
    final primary = PrimaryScrollController.of(context);
    return GradientBackground(
      child: Scaffold(
        backgroundColor: Color(0xFF0D1B2A),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Biblioteca",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              // BOTÓN DESCARGAR TODAS
              Padding(
                padding: const EdgeInsets.symmetric(),
                child: ElevatedButton(
                  onPressed: dm.isRunning ? null : downloadAll,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 20,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: Text(
                    dm.isRunning ? "Descargando..." : "Descargar todas",
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        body: NestedScrollView(
          floatHeaderSlivers: true,
          headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
            return [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                pinned: false,
                floating: true,
                expandedHeight: 0,
                automaticallyImplyLeading: false,
                snap: true,
                flexibleSpace: FlexibleSpaceBar(),

                title: Padding(
                  padding: const EdgeInsets.all(0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: filterSongs,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: "Buscar canción, artista o álbum...",
                            hintStyle: const TextStyle(color: Colors.white54),
                            filled: true,
                            fillColor: Colors.white12,
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Colors.white70,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ];
          },
          body: Column(
            children: [
              // BUSCADOR

              // PROGRESO GLOBAL
              if (dm.isRunning)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LinearProgressIndicator(
                    value: dm.progress,
                    color: Colors.greenAccent,
                    backgroundColor: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

              const SizedBox(height: 5),

              // PROGRESO TTML
              if (dm.isRunning)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: LinearProgressIndicator(
                    value: ttmlProgress,
                    color: Colors.blueAccent,
                    backgroundColor: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              // LISTA FILTRADA
              Expanded(
                child: filteredSongs.isEmpty
                    ? const Center(
                        child: Text(
                          "No se encontraron canciones.",
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : ScrollConfiguration(
                        behavior: const MaterialScrollBehavior().copyWith(
                          dragDevices: {PointerDeviceKind.touch},
                        ),

                        child: Scrollbar(
                          controller: primary,
                          //controller: _scrollController,
                          thumbVisibility: true,
                          thickness: 7,
                          interactive: true,
                          radius: Radius.circular(10),
                          child: RepaintBoundary(
                            child: ListView.builder(
                              //controller: _scrollController,
                              controller: primary,
                              physics: const BouncingScrollPhysics(),
                              itemCount: filteredSongs.length,
                              itemBuilder: (_, i) {
                                final song = filteredSongs[i];
                                final lrcExists = hasLrc(song);

                                return GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            LyricsViewer(song: song),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Row(
                                      children: [
                                        // Portada
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          //Hero(
                                          //tag: song.path,
                                          child: artworkCache[song.path] != null
                                              ? ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  child: Image.memory(
                                                    artworkCache[song.path]!,
                                                    height: 65,
                                                    width: 65,
                                                    fit: BoxFit.cover,
                                                  ),
                                                )
                                              : Container(
                                                  height: 65,
                                                  width: 65,
                                                  decoration: BoxDecoration(
                                                    color: Colors.white12,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  child: const Icon(
                                                    Icons.music_note,
                                                    color: Colors.white70,
                                                    size: 32,
                                                  ),
                                                ),
                                          //),
                                        ),

                                        const SizedBox(width: 14),

                                        // Título y Artista
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                song.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                "${song.artist} • ${song.album}",
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                        const SizedBox(width: 12),

                                        // Descarga / loader / check
                                        (lrcExists && hasTtml(song))
                                            ? const Icon(
                                                Icons.check_circle,
                                                color: Colors.greenAccent,
                                                size: 28,
                                              )
                                            : downloadingSongs.contains(
                                                    song.path,
                                                  ) ||
                                                  dm.isRunning
                                            ? const SizedBox(
                                                width: 26,
                                                height: 26,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.5,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : IconButton(
                                                onPressed: () =>
                                                    downloadOne(song),
                                                icon: const Icon(
                                                  Icons.download,
                                                  color: Colors.white,
                                                  size: 26,
                                                ),
                                              ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
