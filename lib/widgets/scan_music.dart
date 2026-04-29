import 'package:flutter/material.dart';
import 'package:timelyr/services/file_service.dart';
import 'package:timelyr/utils/app_storage.dart';
import '../utils/default_music_path.dart';
import 'select_directory.dart';

class ScanMusic extends StatelessWidget {
  const ScanMusic({super.key});

  String get rootPath =>
      SelectDirectory.selectedPath ?? DefaultMusicPath.defaultPath;
  bool onScan(String path, int scannedFiles, int foundSongs) {
    // You can implement any UI update logic here if needed
    return true; // Return true to continue scanning
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D1B2A),
      title: const Text(
        'Desea  volver a escanear su música?',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(false);
          },
          child: const Text('Cancelar', style: TextStyle(color: Colors.white)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.black87,
          ),
          onPressed: () async {
            final path = rootPath;
            await AppStorage.saveFolder(path);
            await FileService.scanMusicWithCallback(
              path,
              onScan: (_, __, ___) {},
            );
            if (context.mounted) {
              Navigator.of(context).pop(true);
            }
          },
          child: const Text(
            'Escanear Música',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}
