import 'dart:io';
import 'package:flutter/material.dart';
import 'package:timelyr/models/lyric_result.dart';
import 'package:timelyr/services/file_service.dart';
import '../models/song.dart';
import 'package:path/path.dart' as p;

class LyricPreviewScreen extends StatelessWidget {
  final LyricResult result;
  //final String? savePath; // ruta del archivo .lrc de la canción original
  final Song song;

  const LyricPreviewScreen({
    super.key,
    required this.result,
    //this.savePath,
    required this.song,
  });

  @override
  Widget build(BuildContext context) {
    final lyrics = result.isInstrumental == true
        ? "[ar:${result.artist}]\n[al:${result.album}]\n[ti:${result.title}]\n[Instrumental]\n[by:TimeLyr]\n[source:LRCLib.net]"
        : (result.syncedLyrics.isNotEmpty
              ? result.syncedLyrics
              : result.plainLyrics);

    String formatDuration(double seconds) {
      final int total = seconds.floor();
      final int minutes = total ~/ 60;
      final int remaining = total % 60;

      return "$minutes:${remaining.toString().padLeft(2, '0')}";
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(result.title, style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // INFO DE LA CANCIÓN
              Text(
                result.title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "${result.artist} • ${result.album} • ${formatDuration(result.durationSeconds)} min",
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),

              const SizedBox(height: 20),

              // LETRA
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: result.isInstrumental != true
                    ? Text(
                        lyrics,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      )
                    : Text(
                        "Esta canción es instrumental y no contiene letra.",
                        style: TextStyle(
                          color: Colors.white70,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
              ),

              //if (result.isInstrumental == true)
              const SizedBox(height: 30),
              // BOTONES
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Seleccionar esta letra
                  ElevatedButton.icon(
                    onPressed: () async {
                      // Verificar si ya existe un archivo .lrc
                      final file = File(song.path);
                      final filename = p.basenameWithoutExtension(file.path);
                      final lrcPath = "${file.parent.path}/$filename.lrc";
                      final lrcFile = File(lrcPath);

                      bool shouldSave = true;

                      if (lrcFile.existsSync()) {
                        // Mostrar diálogo de confirmación
                        if (!context.mounted) return;

                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (BuildContext dialogContext) {
                            return AlertDialog(
                              backgroundColor: const Color(0xFF1B2838),
                              title: const Text(
                                "Reemplazar letra existente",
                                style: TextStyle(color: Colors.white),
                              ),
                              content: const Text(
                                "Esta canción ya tiene letra. ¿Deseas reemplazarla con la nueva letra?",
                                style: TextStyle(color: Colors.white70),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(false),
                                  child: const Text(
                                    "Cancelar",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () =>
                                      Navigator.of(dialogContext).pop(true),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blueAccent,
                                  ),
                                  child: const Text(
                                    "Reemplazar",
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ],
                            );
                          },
                        );

                        shouldSave = confirmed ?? false;
                      }

                      if (shouldSave) {
                        try {
                          // Guardar la nueva letra (sobrescribe si existe)
                          final lyricsContent =
                              '$lyrics\n[ar:${song.artist.toString()}]\n[al:${song.album.toString()}]\n[ti:${song.title.toString()}]\n\n[by:TimeLyr]\n[source:LRCLib.net]';

                          // Usar writeAsString con flush
                          await lrcFile.writeAsString(lyricsContent);

                          // Pequeña espera para asegurar que se escribió
                          await Future.delayed(
                            const Duration(milliseconds: 300),
                          );

                          // Intentar también descargar/guardar TTML desde Lyrics+ (no bloqueante)
                          try {
                            FileService.saveTTMLForSong(song.path, song);
                          } catch (_) {}

                          if (!context.mounted) return;

                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Letra guardada como archivo .lrc"),
                            ),
                          );

                          if (!context.mounted) return;
                          // ignore: use_build_context_synchronously
                          Navigator.pop(context, result);
                        } catch (e) {
                          if (!context.mounted) return;
                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                "Error al guardar la letra: ${e.toString()}",
                              ),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.check, color: Colors.white),
                    label: const Text(
                      "Usar esta letra",
                      style: TextStyle(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                    ),
                  ),

                  // if (savePath != null)
                  /*ElevatedButton.icon(
                    onPressed: () async {
                      await FileService.saveLRC(savePath!, lyrics);
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Letra guardada como archivo .lrc"),
                        ),
                      );
                    },
                    icon: const Icon(Icons.save),
                    label: const Text("Guardar"),
                  ),*/
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
