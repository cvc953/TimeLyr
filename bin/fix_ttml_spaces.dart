// Script para probar la función de agregar espacio entre spans en un TTML
import 'dart:io';
import 'package:timelyr/services/kpoe_remote_service.dart';

void main() async {
  final path = 'blink-182 - All The Small Things.ttml';
  if (!await File(path).exists()) {
    print('Archivo no encontrado: $path');
    return;
  }
  final original = await File(path).readAsString();
  final corregido = KpoeRemoteService.agregarEspacioEntreSpans(original);
  final outPath = 'blink-182 - All The Small Things.fixed.ttml';
  await File(outPath).writeAsString(corregido);
  print('Archivo corregido guardado en $outPath');
}
