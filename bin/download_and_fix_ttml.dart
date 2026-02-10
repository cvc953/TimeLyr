// Script para descargar el TTML y luego corregir los espacios entre spans
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:timelyr/services/kpoe_remote_service.dart';

void main() async {
  final url =
      'https://lyricsplus-seven.vercel.app/v1/ttml/get?title=All%20The%20Small%20Things&artist=blink-182';
  final ttmlPath = 'blink-182 - All The Small Things.ttml';
  final fixedPath = 'blink-182 - All The Small Things.fixed.ttml';

  print('Descargando TTML...');
  final res = await http.get(Uri.parse(url));
  if (res.statusCode != 200) {
    print('Error al descargar: ${res.statusCode}');
    return;
  }

  // Extraer el campo ttml del JSON
  final ttmlJson = res.body;
  final ttml = KpoeRemoteService.convertKpoeJsonToTtml(ttmlJson);
  await File(ttmlPath).writeAsString(ttml);
  print('TTML guardado en $ttmlPath');

  // Corregir espacios entre spans
  final corregido = KpoeRemoteService.agregarEspacioEntreSpans(ttml);
  await File(fixedPath).writeAsString(corregido);
  print('Archivo corregido guardado en $fixedPath');
}
