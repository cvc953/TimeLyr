import 'dart:io';
import 'package:timelyr/services/kpoe_remote_service.dart';

void main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '/tmp/user_ttml.json';
  final inFile = File(path);
  if (!await inFile.exists()) {
    stderr.writeln('Input file not found: $path');
    exit(2);
  }
  final content = await inFile.readAsString();
  try {
    final out = KpoeRemoteService.convertKpoeJsonToTtml(content);
    final outPath = '/tmp/user_ttml_app_out.xml';
    await File(outPath).writeAsString(out, flush: true);
    stdout.writeln(out);
  } catch (e, st) {
    stderr.writeln('Conversion failed: $e\n$st');
    exit(1);
  }
}
