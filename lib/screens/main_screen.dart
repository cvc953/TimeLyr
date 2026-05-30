import 'package:flutter/material.dart';
import 'package:timelyr/utils/song_database.dart';
import '../widgets/gradient_background.dart';
import 'library_screen.dart';
import 'more_screen.dart';
import '../utils/default_music_path.dart';
import '../utils/app_storage.dart';
import '../services/file_service.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    LibraryScreen(),
    //SearchScreen(),
    MoreScreen(),
  ];

  bool _loading = true;
  bool _isBackgroundScanning = false;
  int _scanScanned = 0;
  int _scanFound = 0;

  Future<void> _startBackgroundScan(String folder) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _isBackgroundScanning = true;
      _scanScanned = 0;
      _scanFound = 0;
    });

    try {
      await FileService.scanMusicWithCallback(
        folder,
        onScan: (_, scanned, found) {
          if (!mounted) {
            return;
          }

          // Reducir rebuilds: solo actualizar cada 25 archivos o cuando aumenta found
          final shouldRebuild =
              scanned == 1 ||
              scanned % 25 == 0 ||
              found != _scanFound ||
              !_isBackgroundScanning;

          if (!shouldRebuild) {
            return;
          }

          setState(() {
            _scanScanned = scanned;
            _scanFound = found;
          });
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBackgroundScanning = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    loadCachedSongs();
  }

  Future<void> loadCachedSongs() async {
    final cached = await SongDatabase.load();
    FileService.setLibrarySongs(cached);

    String? folder = await AppStorage.loadFolder();

    if (folder == null) {
      folder = DefaultMusicPath.defaultPath;
      await AppStorage.saveFolder(folder);
    }
    final scanOnOpen = await AppStorage.loadWatcherEnabled();

    setState(() {
      _loading = false;
    });

    if (scanOnOpen) {
      _startBackgroundScan(folder);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const GradientBackground(
        child: Scaffold(
          backgroundColor: Color(0xFF0D1B2A),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 20),
                Text(
                  "Cargando tu biblioteca...",
                  style: TextStyle(fontSize: 18, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Color(0xFF0D1B2A),
        body: Column(
          children: [
            if (_isBackgroundScanning)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: Colors.white.withValues(alpha: 0.06),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Escaneando tu biblioteca...",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "$_scanScanned archivos revisados • $_scanFound canciones encontradas",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(
                      color: Colors.blueAccent,
                      backgroundColor: Colors.white24,
                    ),
                  ],
                ),
              ),
            Expanded(child: _pages[_currentIndex]),
          ],
        ),
        bottomNavigationBar: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: const Color(0xFF0D1B2A),
            indicatorColor: Colors.blueAccent.withValues(alpha: 0.25),

            labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((
              states,
            ) {
              if (states.contains(WidgetState.selected)) {
                return const TextStyle(color: Colors.white, fontSize: 12);
              }
              return const TextStyle(color: Colors.white70, fontSize: 12);
            }),
          ),
          child: NavigationBar(
            backgroundColor: const Color(0xFF0D1B2A),
            indicatorColor: Colors.blueAccent.withValues(alpha: 0.25),
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) {
              setState(() => _currentIndex = i);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined, color: Colors.white70),
                selectedIcon: Icon(Icons.library_music, color: Colors.white),
                label: "Biblioteca",
              ),
              NavigationDestination(
                icon: Icon(Icons.more_horiz, color: Colors.white70),
                selectedIcon: Icon(Icons.more, color: Colors.white),
                label: "Más",
              ),
            ],
          ),
        ),
      ),
    );
  }
}
