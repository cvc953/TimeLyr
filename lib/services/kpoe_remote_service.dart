import 'dart:io';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timelyr/models/lyric_result.dart';

class KpoeRemoteService {
  static const List<String> _kpoeServers = [
    "https://lyricsplus-seven.vercel.app",
    "https://lyricsplus.prjktla.workers.dev",
    "https://lyrics-plus-backend.vercel.app",
  ];

  static Future<LyricResult?> getKpoeLyrics({
    required String artist,
    required String title,
    required String album,
    required int durationSeconds,
  }) async {
    final safeArtist = (artist.isEmpty) ? "" : artist.trim();
    final safeTitle = (title.isEmpty) ? "" : title.trim();
    final safeAlbum = (album.isEmpty) ? "" : album.trim();

    final safeDuration = (durationSeconds <= 0)
        ? ""
        : durationSeconds.toString();

    final uri = Uri.parse(
      "https://lyricsplus-seven.vercel.app/v1/ttml/get"
      "?artist_name=${Uri.encodeComponent(safeArtist)}"
      "&track_name=${Uri.encodeComponent(safeTitle)}"
      "&album_name=${Uri.encodeComponent(safeAlbum)}"
      "&duration=$safeDuration",
    );

    final r = await http.get(uri);

    if (r.statusCode == 200 && r.body.isNotEmpty && r.body != "{}") {
      return LyricResult.fromJson(json.decode(r.body));
    }
    return null;
  }

  static String convertKpoeJsonToTtml(
    String jsonString, {
    String? title,
    String? artist,
    int? version,
  }) {
    final trimmed = jsonString.trimLeft();
    if (trimmed.startsWith('<?xml') ||
        trimmed.startsWith('<tt') ||
        trimmed.startsWith('<!DOCTYPE')) {
      return _normalizeTimestampsInString(jsonString);
    }

    Map<String, dynamic> root;
    try {
      root = json.decode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      if (_looksLikeLrc(jsonString)) {
        final ttml = _lrcToTtml(
          jsonString,
          title: title,
          artist: artist,
          version: version,
        );
        final marked = _markInterSpanSpaces(ttml);
        final formatted = _formatXml(marked);
        final restored = _restoreInterSpanSpaces(formatted);
        return _normalizeTimestampsInString(_ensureXmlDeclaration(restored));
      }
      final ttml = _minimalTtmlFromText(
        jsonString,
        title: title,
        artist: artist,
        version: version,
      );
      final marked = _markInterSpanSpaces(ttml);
      final formatted = _formatXml(marked);
      final restored = _restoreInterSpanSpaces(formatted);
      return _normalizeTimestampsInString(_ensureXmlDeclaration(restored));
    }

    if (root.containsKey('ttml') && root['ttml'] is String) {
      final rawTtml = root['ttml'] as String;
      final marked = _markInterSpanSpaces(rawTtml);
      final formatted = _formatXml(marked);
      final restored = _restoreInterSpanSpaces(formatted);
      return _normalizeTimestampsInString(_ensureXmlDeclaration(restored));
    }

    final lyrics =
        root['lyrics'] as List<dynamic>? ??
        root['data'] as List<dynamic>? ??
        [];

    String esc(String s) => _esc(s);
    String msToTimestamp(num ms) => _msToTimestamp(ms);

    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="utf-8"?>');
    sb.writeln('<tt xmlns="http://www.w3.org/ns/ttml">');
    sb.writeln('  <head>');
    sb.writeln('    <metadata>');
    if ((title ?? '').isNotEmpty || (artist ?? '').isNotEmpty) {
      sb.writeln(
        '      <title>${esc('${title ?? ''}${title != null && artist != null ? ' - ' : ''}${artist ?? ''}').trim()}</title>',
      );
    }
    if (version != null)
      sb.writeln('      <comment>version:$version</comment>');
    sb.writeln('    </metadata>');
    sb.writeln('  </head>');
    sb.writeln('  <body>');
    sb.writeln('    <div>');

    for (final item in lyrics) {
      if (item == null) continue;
      final obj = item is Map ? item as Map<String, dynamic> : null;
      final ms = obj != null
          ? (obj['time'] ?? obj['startTime'] ?? obj['start'] ?? 0)
          : 0;
      final dur = obj != null ? (obj['duration'] ?? 0) : 0;
      final text = obj != null ? (obj['text'] ?? obj['lyrics'] ?? '') : '';

      final begin = msToTimestamp(num.parse(ms.toString()));
      final end = msToTimestamp(num.parse(((ms ?? 0) + (dur ?? 0)).toString()));
      sb.writeln('      <p begin="$begin" end="$end">${esc(text ?? '')}</p>');
    }

    sb.writeln('    </div>');
    sb.writeln('  </body>');
    sb.writeln('</tt>');

    final marked = _markInterSpanSpaces(sb.toString());
    final formatted = _formatXml(marked);
    final restored = _restoreInterSpanSpaces(formatted);
    return _normalizeTimestampsInString(_ensureXmlDeclaration(restored));
  }

  static String _ensureXmlDeclaration(String s) {
    final trimmed = s.trimLeft();
    final declRe = RegExp(r'^<\?xml[^>]*\?>\s*', multiLine: false);
    if (declRe.hasMatch(trimmed)) {
      return trimmed.replaceFirst(
        declRe,
        '<?xml version="1.0" encoding="utf-8"?>\n',
      );
    }
    return '<?xml version="1.0" encoding="utf-8"?>\n' + trimmed;
  }

  static String _normalizeTimestampsInString(String s) {
    try {
      // Normalize attributes like begin="55.013" -> begin="00:55.013"
      // and pad minute/hours to two digits when present: 5:03.120 -> 05:03.120
      return s.replaceAllMapped(RegExp(r'(?:\b(begin|end)\s*=\s*\")([^\"]+)(\")'), (
        m,
      ) {
        final attr = m.group(1)!;
        var val = m.group(2)!;

        // If already contains colon(s), pad the first numeric part to two digits
        if (val.contains(':')) {
          // Split by colon, keep rest intact (supports hh:mm:ss.ms or mm:ss.ms)
          final parts = val.split(':');
          if (parts.isNotEmpty) {
            final first = parts[0];
            final rest = parts.skip(1).join(':');
            final numFirst = int.tryParse(first) ?? 0;
            final padded = numFirst.toString().padLeft(2, '0');
            val = '$padded:${rest}';
          }
        } else {
          // No colon -> prefix with 00:
          val = '00:${val}';
        }

        return '${attr}="${val}"';
      });
    } catch (e) {
      return s;
    }
  }

  static Future<String?> fetchFromKpoe(
    String title,
    String artist, {
    String? album,
    String? duration,
    String format = 'json',
    String? customBaseUrl,
  }) async {
    final safeArtist = (artist.isEmpty) ? "" : artist.trim();
    final safeTitle = (title.isEmpty) ? "" : title.trim();
    final safeAlbum = (album ?? '').trim();

    final safeDuration = (duration == null || duration.isEmpty) ? '' : duration;

    final base = customBaseUrl ?? _kpoeServers.first;

    var qs =
        'artist_name=${Uri.encodeComponent(safeArtist)}'
        '&track_name=${Uri.encodeComponent(safeTitle)}'
        '&album_name=${Uri.encodeComponent(safeAlbum)}'
        '&duration=${Uri.encodeComponent(safeDuration)}';
    qs = qs.replaceAll('%20', '+');

    final url = '${base.replaceAll(RegExp(r'\/\$'), '')}/v1/ttml/get?$qs';

    final headers = {
      'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36',
      'Accept': 'application/ttml+xml, application/xml, text/xml, */*',
    };

    try {
      final r = await http.get(Uri.parse(url), headers: headers);
      print('Kpoe GET $url -> ${r.statusCode} (len=${r.body.length})');
      if (r.statusCode == 200 && r.body.isNotEmpty && r.body != '{}') {
        return r.body;
      }
      return null;
    } catch (e) {
      print('Kpoe fetch error: $e');
      return null;
    }
  }

  static bool _looksLikeLrc(String s) {
    final trimmed = s.trimLeft();
    return RegExp(r'^\[\d{1,2}:\d{2}(?:[:\.]\d{1,3})?\]').hasMatch(trimmed) ||
        RegExp(r'\[\d{1,2}:\d{2}(?:[:\.]\d{1,3})?\]').hasMatch(s);
  }

  static String _lrcToTtml(
    String lrc, {
    String? title,
    String? artist,
    int? version,
  }) {
    final lines = LineSplitter.split(lrc).toList();
    final events = <Map<String, dynamic>>[];
    final tsRe = RegExp(r'\[(\d{1,2}):(\d{2})(?:[:\.](\d{1,3}))?\]');

    for (var line in lines) {
      final matches = tsRe.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.replaceAll(tsRe, '').trim();
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final msPart = m.group(3) != null
            ? int.parse((m.group(3)!).padRight(3, '0'))
            : 0;
        final ms = min * 60 * 1000 + sec * 1000 + msPart;
        events.add({'time': ms, 'text': text});
      }
    }

    if (events.isEmpty)
      return _minimalTtmlFromText(
        lrc,
        title: title,
        artist: artist,
        version: version,
      );

    events.sort((a, b) => (a['time'] as int).compareTo(b['time'] as int));

    String msToTimestamp(num ms) => _msToTimestamp(ms);
    String esc(String s) => _esc(s);

    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="utf-8"?>');
    sb.writeln('<tt xmlns="http://www.w3.org/ns/ttml">');
    sb.writeln('  <head>');
    sb.writeln('    <metadata>');
    if ((title ?? '').isNotEmpty || (artist ?? '').isNotEmpty) {
      sb.writeln(
        '      <title>${esc('${title ?? ''}${title != null && artist != null ? ' - ' : ''}${artist ?? ''}').trim()}</title>',
      );
    }
    if (version != null)
      sb.writeln('      <comment>version:$version</comment>');
    sb.writeln('    </metadata>');
    sb.writeln('  </head>');
    sb.writeln('  <body>');
    sb.writeln('    <div>');

    for (var i = 0; i < events.length; i++) {
      final cur = events[i];
      final nextTime = i + 1 < events.length
          ? events[i + 1]['time'] as int
          : (cur['time'] as int) + 3000;
      final begin = msToTimestamp(cur['time']);
      final end = msToTimestamp(nextTime);
      sb.writeln(
        '      <p begin="${begin}" end="${end}">${esc(cur['text'] ?? '')}</p>',
      );
    }

    sb.writeln('    </div>');
    sb.writeln('  </body>');
    sb.writeln('</tt>');
    return sb.toString();
  }

  static String _msToTimestamp(num ms) {
    final totalMs = ms.toInt();
    final msPart = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final sec = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final min = totalMin % 60;
    final hour = totalMin ~/ 60;
    return '${hour.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${msPart.toString().padLeft(3, '0')}';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _minimalTtmlFromText(
    String text, {
    String? title,
    String? artist,
    int? version,
  }) {
    final esc = (String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="utf-8"?>');
    sb.writeln('<tt xmlns="http://www.w3.org/ns/ttml">');
    sb.writeln('  <head>');
    sb.writeln('    <metadata>');
    if ((title ?? '').isNotEmpty || (artist ?? '').isNotEmpty) {
      sb.writeln(
        '      <title>${esc('${title ?? ''}${title != null && artist != null ? ' - ' : ''}${artist ?? ''}').trim()}</title>',
      );
    }
    if (version != null)
      sb.writeln('      <comment>version:$version</comment>');
    sb.writeln('    </metadata>');
    sb.writeln('  </head>');
    sb.writeln('  <body>');
    sb.writeln('    <div>');
    sb.writeln('      <p>${esc(text)}</p>');
    sb.writeln('    </div>');
    sb.writeln('  </body>');
    sb.writeln('</tt>');
    return sb.toString();
  }

  static Future<File> saveStringToDownloads(
    String filename,
    String content,
  ) async {
    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) throw Exception('Storage permission denied');
        final dirs = await getExternalStorageDirectories(
          type: StorageDirectory.downloads,
        );
        Directory dir;
        if (dirs != null && dirs.isNotEmpty)
          dir = dirs.first;
        else
          dir =
              await getExternalStorageDirectory() ??
              await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.create(recursive: true);
        final toWrite = _looksLikeTtml(content) ? _formatXml(content) : content;
        await file.writeAsString(toWrite, flush: true);
        return file;
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.create(recursive: true);
        await file.writeAsString(content, flush: true);
        return file;
      }
    } catch (e) {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return file;
    }
  }

  static bool _looksLikeTtml(String s) {
    final trimmed = s.trimLeft();
    return trimmed.startsWith('<?xml') ||
        trimmed.startsWith('<tt') ||
        trimmed.contains('<tt ');
  }

  static String _formatXml(String xml) {
    try {
      // Reemplaza > < por >\n< excepto si es <span>
      var s = xml.replaceAllMapped(RegExp(r'>(\s*)<'), (m) {
        // Si la siguiente etiqueta es <span, no agregues salto de línea
        final after = xml.substring(
          m.end,
          m.end + 5 > xml.length ? xml.length : m.end + 5,
        );
        if (after.startsWith('span')) return '><';
        // Si la anterior es </span>, tampoco agregues salto de línea
        final before = xml.substring(
          m.start - 6 < 0 ? 0 : m.start - 6,
          m.start,
        );
        if (before.endsWith('/span')) return '><';
        return '>\n<';
      });
      // Ahora, para cada línea, solo indenta si no es <span> ni </span>
      final lines = s.split('\n');
      final sb = StringBuffer();
      int indent = 0;
      String indentStr(int n) => '  ' * n;
      for (var raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('<?') && line.endsWith('?>')) {
          sb.writeln(line);
          continue;
        }
        if (line.startsWith('</')) {
          indent = (indent - 1).clamp(0, 9999);
          // Si es </span>, no indentes ni hagas salto de línea
          if (line.startsWith('</span')) {
            sb.write(line);
            continue;
          }
          sb.writeln('${indentStr(indent)}$line');
          // Si es </p>, agrega salto de línea extra
          if (line.startsWith('</p')) {
            sb.writeln();
          }
          continue;
        }
        // Si es <span>, no indentes ni hagas salto de línea
        if (line.startsWith('<span')) {
          sb.write(line);
          continue;
        }
        final isSelfClosing = line.endsWith('/>');
        final isOpeningTag = line.startsWith('<') && !line.startsWith('</');
        sb.writeln('${indentStr(indent)}$line');
        if (isOpeningTag && !isSelfClosing && !line.startsWith('<?')) {
          indent++;
        }
      }
      return sb.toString();
    } catch (e) {
      return xml;
    }
  }

  // Marca los lugares donde entre dos spans había espacios originalmente,
  // para preservarlos durante el formateo (que puede normalizar/eliminar
  // espacios entre etiquetas). Se usa un placeholder HTML comment.
  static String _markInterSpanSpaces(String s) {
    try {
      return s.replaceAllMapped(
        RegExp(r'</span>\s+<span'),
        (m) => '</span><!--SPL--><span',
      );
    } catch (e) {
      return s;
    }
  }

  // Restaura el marcador por un espacio real después del formateo.
  static String _restoreInterSpanSpaces(String s) {
    try {
      return s.replaceAll('<!--SPL-->', ' ');
    } catch (e) {
      return s;
    }
  }

  /// Procesa un string XML y agrega espacio al final de la palabra dentro de <span> solo si hay espacio entre ese <span> y el siguiente.
  static String agregarEspacioEntreSpans(String xml) {
    final spanRegex = RegExp(r'<span[^>]*>([^<]*)<\/span>');
    final buffer = StringBuffer();
    int lastEnd = 0;
    final matches = spanRegex.allMatches(xml).toList();

    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      // Añade el texto entre el final del último match y el inicio del actual
      buffer.write(xml.substring(lastEnd, match.start));
      String palabra = match.group(1)!;
      String spanTag = match.group(0)!;
      // Verifica si hay espacio después del span actual
      bool hayEspacio = false;
      if (i < matches.length - 1) {
        int afterSpan = match.end;
        int nextSpanStart = matches[i + 1].start;
        String entreSpans = xml.substring(afterSpan, nextSpanStart);
        hayEspacio = entreSpans.contains(' ');
      }
      // Si hay espacio, agrega espacio al final de la palabra
      if (hayEspacio) {
        // Reconstruye el span con espacio
        spanTag = spanTag.replaceFirst('>$palabra<', '>${palabra} <');
      }
      buffer.write(spanTag);
      lastEnd = match.end;
    }
    // Añade el resto del texto
    buffer.write(xml.substring(lastEnd));
    return buffer.toString();
  }
}
