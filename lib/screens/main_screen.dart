import 'package:flutter/material.dart';
import 'package:timelyr/utils/song_database.dart';
import 'dart:io';
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

  @override
  void initState() {
    super.initState();
    loadCachedSongs();
  }

  Future<void> loadCachedSongs() async {
    final cached = await SongDatabase.load();
    FileService.librarySongs = cached;

    String? folder = await AppStorage.loadFolder();

    if (folder == null) {
      folder = DefaultMusicPath.defaultPath;
      await AppStorage.saveFolder(folder);
    }

    // Auto-escaneo para detectar canciones nuevas
    if (Directory(folder).existsSync()) {
      await FileService.scanMusicWithCallback(
        folder,
        onScan: (path, scanned, found) {
          // Silent scan
        },
      );
    }

    setState(() {
      _loading = false;
    });
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
                  "Escaneando tu música...",
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
        body: _pages[_currentIndex],
        bottomNavigationBar: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: const Color(0xFF0D1B2A),
            indicatorColor: Colors.blueAccent.withOpacity(0.25),

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
            indicatorColor: Colors.blueAccent.withOpacity(0.25),
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
