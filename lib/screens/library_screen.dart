import 'dart:async';
import 'dart:io';
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

enum LyricFilter { all, noLyrics, lrcOnly, ttmlReady }

enum SongLyricState { noLyrics, lrcOnly, ttmlReady }

class _LyricStatus {
  final bool hasLrc;
  final bool hasTtml;

  const _LyricStatus({required this.hasLrc, required this.hasTtml});
}

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
  final Set<String> _artworkLoading = {};
  final Map<String, _LyricStatus> _lyricStatusByPath = {};
  final Map<String, String> _searchBlobByPath = {};
  final dm = DownloadManager.instance;
  double ttmlProgress = 0.0;
  LyricFilter _lyricFilter = LyricFilter.all;
  String _searchQuery = '';
  Timer? _searchDebounce;
  int _lyricStatusRefreshRequestId = 0;

  @override
  void dispose() {
    _librarySub?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    allSongs = FileService.librarySongs;
    filteredSongs = List.from(allSongs);
    filteredSongs.sort((a, b) => a.title.compareTo(b.title));
    _refreshSearchCache(allSongs);
    unawaited(_refreshLyricStatusCache(allSongs, reapplyFilters: true));
    // Escuchar cambios en la librería (p. ej. watcher en background)
    _librarySub = FileService.libraryUpdateController.stream.listen((_) {
      allSongs = FileService.librarySongs;
      _refreshSearchCache(allSongs);
      _applyFilters();
      unawaited(_refreshLyricStatusCache(allSongs, reapplyFilters: true));
    });
  }

  StreamSubscription<void>? _librarySub;

  SongLyricState _songLyricState(_LyricStatus status) {
    if (status.hasTtml) {
      return SongLyricState.ttmlReady;
    }
    if (status.hasLrc) {
      return SongLyricState.lrcOnly;
    }
    return SongLyricState.noLyrics;
  }

  Future<_LyricStatus> _buildLyricStatus(Song song) async {
    final file = File(song.path);
    final filename = p.basenameWithoutExtension(file.path);
    final lrcFile = File("${file.parent.path}/$filename.lrc");
    final ttmlFile = File("${file.parent.path}/$filename.ttml");

    return _LyricStatus(
      hasLrc: await lrcFile.exists(),
      hasTtml: await ttmlFile.exists(),
    );
  }

  void _refreshSearchCache(List<Song> songs) {
    _searchBlobByPath.clear();
    for (final song in songs) {
      _searchBlobByPath[song.path] =
          "${song.title} ${getPrimaryArtist(song.artist)} ${song.album}"
              .toLowerCase();
    }
  }

  Future<void> _refreshLyricStatusCache(
    List<Song> songs, {
    bool reapplyFilters = false,
  }) async {
    final requestId = ++_lyricStatusRefreshRequestId;
    final statusEntries = await Future.wait(
      songs.map((song) async {
        final status = await _buildLyricStatus(song);
        return MapEntry(song.path, status);
      }),
    );

    if (!mounted || requestId != _lyricStatusRefreshRequestId) {
      return;
    }

    _lyricStatusByPath
      ..clear()
      ..addEntries(statusEntries);

    if (reapplyFilters) {
      _applyFilters();
    }
  }

  Future<void> _queueArtworkLoad(Song song) async {
    if (artworkCache.containsKey(song.path) ||
        _artworkLoading.contains(song.path)) {
      return;
    }

    _artworkLoading.add(song.path);

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

      if (!mounted) {
        return;
      }

      setState(() {
        artworkCache[song.path] = artwork;
      });
    } catch (e) {
      // Silenciar errores individuales para no bloquear la carga
      if (!mounted) {
        return;
      }

      setState(() {
        artworkCache[song.path] = null;
      });
    } finally {
      _artworkLoading.remove(song.path);
    }
  }

  void filterSongs(String query) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || _searchQuery == query) {
        return;
      }

      _searchQuery = query;
      _applyFilters();
    });
  }

  void _applyFilters() {
    final normalizedQuery = _searchQuery.toLowerCase();
    setState(() {
      filteredSongs = allSongs.where((song) {
        final lyricStatus =
            _lyricStatusByPath[song.path] ??
            const _LyricStatus(hasLrc: false, hasTtml: false);

        final searchBlob = _searchBlobByPath[song.path] ?? '';
        final bool matchesQuery =
            normalizedQuery.isEmpty || searchBlob.contains(normalizedQuery);

        bool matchesLyricFilter = true;
        final songState = _songLyricState(lyricStatus);
        switch (_lyricFilter) {
          case LyricFilter.ttmlReady:
            matchesLyricFilter = songState == SongLyricState.ttmlReady;
            break;
          case LyricFilter.lrcOnly:
            matchesLyricFilter = songState == SongLyricState.lrcOnly;
            break;
          case LyricFilter.noLyrics:
            matchesLyricFilter = songState == SongLyricState.noLyrics;
            break;
          case LyricFilter.all:
            matchesLyricFilter = true;
            break;
        }

        return matchesQuery && matchesLyricFilter;
      }).toList();
    });
  }

  Future<void> downloadOne(Song song) async {
    setState(() {
      downloadingSongs.add(song.path);
    });

    final result = await LyricsService.downloadAndSaveResult(song);

    setState(() {
      downloadingSongs.remove(song.path);
    });

    if (!result.saved) {
      if (!mounted) {
        return;
      }
      final message = result.failure == LyricsFetchFailure.network
          ? (result.message ??
                "Error técnico al descargar letras. Verificá tu conexión e intentá de nuevo.")
          : "No se encontró letra para ${song.title}";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }

    _lyricStatusByPath[song.path] = await _buildLyricStatus(song);
    _applyFilters();
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
    final listWithoutLrc = listToDownload.where((song) {
      final status =
          _lyricStatusByPath[song.path] ??
          const _LyricStatus(hasLrc: false, hasTtml: false);
      return !status.hasLrc;
    }).toList();
    final listWithLrc = listToDownload.where((song) {
      final status =
          _lyricStatusByPath[song.path] ??
          const _LyricStatus(hasLrc: false, hasTtml: false);
      return status.hasLrc;
    }).toList();
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

    final statusEntries = await Future.wait(
      listToDownload.map((song) async {
        final status = await _buildLyricStatus(song);
        return MapEntry(song.path, status);
      }),
    );
    for (final entry in statusEntries) {
      _lyricStatusByPath[entry.key] = entry.value;
    }
    _applyFilters();

    if (!mounted) {
      return;
    }
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
            : _lyricFilter == LyricFilter.ttmlReady
            ? Icons.check_circle
            : _lyricFilter == LyricFilter.lrcOnly
            ? Icons.library_music
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
          value: LyricFilter.ttmlReady,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "TTML listo",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
        PopupMenuItem<LyricFilter>(
          value: LyricFilter.lrcOnly,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Solo LRC",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
        PopupMenuItem<LyricFilter>(
          value: LyricFilter.noLyrics,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Sin letras",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ).then((LyricFilter? selectedFilter) {
      if (selectedFilter != null && selectedFilter != _lyricFilter) {
        _lyricFilter = selectedFilter;
        // Refiltrar con el mismo query para aplicar el nuevo filtro
        _applyFilters();
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
    final lyricStatus =
        _lyricStatusByPath[song.path] ??
        const _LyricStatus(hasLrc: false, hasTtml: false);
    final songState = _songLyricState(lyricStatus);
    unawaited(_queueArtworkLoad(song));

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

        _buildLyricStateChip(songState),

        const SizedBox(width: 8),

        // Descarga / loader / check
        (songState == SongLyricState.ttmlReady)
            ? const Icon(
                Icons.check_circle,
                color: Colors.greenAccent,
                size: 28,
              )
            : (songState == SongLyricState.lrcOnly)
            ? const Icon(
                Icons.library_music,
                color: Colors.amberAccent,
                size: 26,
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

  Widget _buildLyricStateChip(SongLyricState state) {
    switch (state) {
      case SongLyricState.ttmlReady:
        return _stateChip(
          label: 'TTML listo',
          color: Colors.greenAccent,
        );
      case SongLyricState.lrcOnly:
        return _stateChip(
          label: 'Solo LRC',
          color: Colors.amberAccent,
        );
      case SongLyricState.noLyrics:
        return _stateChip(
          label: 'Sin letras',
          color: Colors.white60,
        );
    }
  }

  Widget _stateChip({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
