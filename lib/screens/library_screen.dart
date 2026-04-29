import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:timelyr/utils/artwork_cache.dart';
import '../widgets/gradient_background.dart';
import '../services/file_service.dart';
import '../services/metadata_reader.dart';
import '../services/lyrics_service.dart';
import '../utils/lyrics_utils.dart';
import '../models/song.dart';
import 'lyrics_viewer.dart';
import 'dart:typed_data';
import '../services/download_manager.dart';
import 'package:path/path.dart' as p;

enum LyricFilter { all, withLyrics, withoutLyrics }

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
  LyricFilter _lyricFilter = LyricFilter.all;

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
    // Cargar artwork en paralelo con un límite de concurrencia
    const int concurrencyLimit = 4;
    final List<Future<void>> tasks = [];

    for (var song in allSongs) {
      tasks.add(_loadSingleArtwork(song));

      // Procesar en lotes para no sobrecargar
      if (tasks.length >= concurrencyLimit) {
        await Future.wait(tasks);
        tasks.clear();
        // Actualizar UI periódicamente durante la carga
        if (mounted) setState(() {});
      }
    }

    // Procesar las tareas restantes
    if (tasks.isNotEmpty) {
      await Future.wait(tasks);
    }

    if (mounted) setState(() {});
  }

  Future<void> _loadSingleArtwork(Song song) async {
    try {
      // Primero intentar desde el caché de disco
      Uint8List? artwork = await ArtworkCache.load(song.path);

      if (artwork == null) {
        // Extraer del archivo de audio directamente
        final metadata = await MetadataReader.getMetadata(song.path);
        if (metadata != null && metadata['artwork'] is Uint8List) {
          artwork = metadata['artwork'] as Uint8List;
          // Guardar en caché de disco para la próxima vez
          await ArtworkCache.save(song.path, artwork);
        }
      }

      artworkCache[song.path] = artwork;
    } catch (e) {
      // Silenciar errores individuales para no bloquear la carga
      artworkCache[song.path] = null;
    }
  }

  void filterSongs(String query) {
    query = query.toLowerCase();

    setState(() {
      filteredSongs = allSongs.where((song) {
        bool matchesQuery =
            song.title.toLowerCase().contains(query) ||
            getPrimaryArtist(song.artist).toLowerCase().contains(query) ||
            song.album.toLowerCase().contains(query);

        bool matchesLyricFilter = true;
        switch (_lyricFilter) {
          case LyricFilter.withLyrics:
            matchesLyricFilter = hasLrc(song) && hasTtml(song);
            break;
          case LyricFilter.withoutLyrics:
            matchesLyricFilter = !hasLrc(song) || !hasTtml(song);
            break;
          case LyricFilter.all:
            matchesLyricFilter = true;
            break;
        }

        return matchesQuery && matchesLyricFilter;
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
    return GradientBackground(
      child: Scaffold(
        backgroundColor: Color(0xFF0D1B2A),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            "Biblioteca",
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        floatingActionButton: floatingActionButton(dm),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [searchBar(), filterBotton()]),
            ),
            progressbar(dm),
            expandedlist(),
          ],
        ), //progressbar(dm),
      ),
    );
  }

  Widget filterBotton() {
    return IconButton(
      icon: Icon(
        _lyricFilter == LyricFilter.all
            ? Icons.filter_list
            : _lyricFilter == LyricFilter.withoutLyrics
            ? Icons.music_note
            : Icons.music_off,
        color: Colors.white,
      ),
      onPressed: () {
        filtermenu();
      },
    );
  }

  Widget floatingActionButton(DownloadManager dm) {
    return FloatingActionButton(
      onPressed: dm.isRunning ? null : downloadAll,
      backgroundColor: Colors.blueAccent,
      child: Icon(
        dm.isRunning ? Icons.downloading : Icons.download,
        color: Colors.white,
      ),
    );
  }

  Widget searchBar() {
    return Expanded(
      flex: 3,
      child: TextField(
        onChanged: filterSongs,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: "Buscar canción, artista o álbum...",
          hintStyle: const TextStyle(color: Colors.white54),
          filled: true,
          fillColor: Colors.white12,
          prefixIcon: const Icon(Icons.search, color: Colors.white70),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        ),
      ),
    );
  }

  void filtermenu() {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 80,
        kToolbarHeight + 8,
        0,
        0,
      ),
      color: Color(0xFF0D1B2A),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem<LyricFilter>(
          value: LyricFilter.all,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text("Todas", style: TextStyle(color: Colors.white)),
          ),
        ),
        PopupMenuItem<LyricFilter>(
          value: LyricFilter.withLyrics,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Con letra",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
        PopupMenuItem<LyricFilter>(
          value: LyricFilter.withoutLyrics,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Sin letra",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ).then((LyricFilter? selectedFilter) {
      if (selectedFilter != null && selectedFilter != _lyricFilter) {
        setState(() {
          _lyricFilter = selectedFilter;
        });
        // Refiltrar con el mismo query para aplicar el nuevo filtro
        filterSongs('');
      }
    });
  }

  Widget progressbar(DownloadManager dm) {
    return Column(
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

        // LISTA FILTRADA
      ],
    );
  }

  Widget expandedlist() {
    return Expanded(
      child: filteredSongs.isEmpty
          ? const Center(
              child: Text(
                "No se encontraron canciones.",
                style: TextStyle(color: Colors.white70),
              ),
            )
          : songlist(),
    );
  }

  Widget scrollbar() {
    final primary = PrimaryScrollController.of(context);

    return Scrollbar(
      controller: primary,
      //controller: _scrollController,
      thumbVisibility: true,
      thickness: 7,
      interactive: true,
      radius: Radius.circular(10),
      child: RepaintBoundary(child: songlist()),
    );
  }

  Widget songlist() {
    final primary = PrimaryScrollController.of(context);

    return ListView.builder(
      //controller: _scrollController,
      controller: primary,
      physics: const BouncingScrollPhysics(),
      itemCount: filteredSongs.length,
      itemBuilder: (_, i) {
        final song = filteredSongs[i];

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LyricsViewer(song: song)),
            );
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(18),
            ),
            child: songitem(song),
          ),
        );
      },
    );
  }

  Widget songitem(Song filteredSongs) {
    final song = filteredSongs;
    final lrcExists = hasLrc(song);

    return Row(
      children: [
        // Portada
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          //Hero(
          //tag: song.path,
          child: artworkCache[song.path] != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
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
                    borderRadius: BorderRadius.circular(12),
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
            crossAxisAlignment: CrossAxisAlignment.start,
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
                style: const TextStyle(color: Colors.white70, fontSize: 14),
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
            : downloadingSongs.contains(song.path) || dm.isRunning
            ? const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : IconButton(
                onPressed: () => downloadOne(song),
                icon: const Icon(Icons.download, color: Colors.white, size: 26),
              ),
      ],
    );
  }
}
