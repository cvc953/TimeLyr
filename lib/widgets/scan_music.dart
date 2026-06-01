import 'package:flutter/material.dart';
import 'package:timelyr/services/file_service.dart';
import 'package:timelyr/utils/app_storage.dart';
import '../utils/default_music_path.dart';
import 'select_directory.dart';

class ScanMusic extends StatefulWidget {
  const ScanMusic({super.key});

  @override
  State<ScanMusic> createState() => _ScanMusicState();
}

class _ScanMusicState extends State<ScanMusic> {
  bool _isScanning = false;
  bool _cancelRequested = false;
  int _scannedFiles = 0;
  int _foundSongs = 0;

  String get rootPath =>
      SelectDirectory.selectedPath ?? DefaultMusicPath.defaultPath;

  void _cancelScan() {
    if (_isScanning) {
      _cancelRequested = true;
      FileService.cancelActiveScan();
    }

    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) {
      return;
    }

    final path = rootPath;
    await AppStorage.saveFolder(path);

    setState(() {
      _isScanning = true;
      _cancelRequested = false;
      _scannedFiles = 0;
      _foundSongs = 0;
    });

    try {
      await FileService.scanMusicWithCallback(
        path,
        onScan: (_, scanned, found) {
          if (!mounted || _cancelRequested) {
            return;
          }

          setState(() {
            _scannedFiles = scanned;
            _foundSongs = found;
          });
        },
      );

      if (!mounted || _cancelRequested) {
        return;
      }

      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al escanear la biblioteca. Intentá de nuevo.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D1B2A),
      title: Text(
        _isScanning
            ? 'Escaneando biblioteca...'
            : 'Desea volver a escanear su música?',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white),
      ),
      content: _isScanning
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(
                  color: Colors.blueAccent,
                  backgroundColor: Colors.white24,
                ),
                const SizedBox(height: 12),
                Text(
                  '$_scannedFiles archivos revisados • $_foundSongs canciones encontradas',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            )
          : null,
      actions: <Widget>[
        TextButton(
          onPressed: _cancelScan,
          child: Text(
            _isScanning ? 'Cancelar escaneo' : 'Cancelar',
            style: const TextStyle(color: Colors.white),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.black87,
          ),
          onPressed: _isScanning ? null : _startScan,
          child: _isScanning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'Escanear Música',
                  style: TextStyle(color: Colors.white),
                ),
        ),
      ],
    );
  }
}
