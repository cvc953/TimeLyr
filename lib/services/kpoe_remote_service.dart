import 'dart:io';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timelyr/models/lyric_result.dart';

class KpoeRemoteService {
  static final Set<String> _temporarilyDisabledBases = <String>{};

  /// Devuelve true si algún <p ...>...</p> no contiene <span> ni </span>.
  static bool hasParagraphWithoutAnySpan(String s) {
    try {
      final re = RegExp(
        r'<p\b[^>]*>([\s\S]*?)<\/p>',
        dotAll: true,
        caseSensitive: false,
      );
      for (final m in re.allMatches(s)) {
        final inner = m.group(1) ?? '';
        if (!inner.contains('<span') && !inner.contains('</span')) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Convierte TTML a líneas LRC (`[mm:ss.xx]texto`).
  ///
  /// Devuelve string vacío cuando no se pudo extraer contenido útil.
  static String convertTtmlToLrc(String ttmlContent) {
    try {
      final paragraphRe = RegExp(
        r'<p\b[^>]*>([\s\S]*?)<\/p>',
        dotAll: true,
        caseSensitive: false,
      );
      final beginRe = RegExp(
        "\\bbegin\\s*=\\s*[\"']([^\"']+)[\"']",
        caseSensitive: false,
      );

      final lines = <String>[];
      for (final m in paragraphRe.allMatches(ttmlContent)) {
        final pBlock = m.group(0) ?? '';
        final inner = m.group(1) ?? '';
        final tsMatch = beginRe.firstMatch(pBlock);
        final lrcTimestamp = _toLrcTimestamp(tsMatch?.group(1));
        final plain = _ttmlInnerToPlainText(inner);
        if (plain.isEmpty) continue;
        lines.add('[$lrcTimestamp]$plain');
      }

      if (lines.isNotEmpty) {
        return lines.join('\n');
      }

      // Fallback mínimo: extraer texto plano global y marcarlo en 00:00.00
      final text = _ttmlInnerToPlainText(ttmlContent);
      if (text.isEmpty) return '';
      return '[00:00.00]$text';
    } catch (_) {
      return '';
    }
  }

  static String _ttmlInnerToPlainText(String source) {
    var out = source;
    out = out.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), ' ');
    out = out.replaceAll(RegExp(r'<[^>]+>'), ' ');
    out = _decodeXmlEntities(out);
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  static String _decodeXmlEntities(String source) {
    return source
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  static String _toLrcTimestamp(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '00:00.00';

    final normalized = _normalizeTimestampsInString('begin="${raw.trim()}"');
    final match = RegExp(r'begin="([0-9]{2}:[0-9]{2}\.[0-9]{2})"').firstMatch(
      normalized,
    );
    if (match != null) {
      return match.group(1)!;
    }
    return '00:00.00';
  }

  static const List<String> _kpoeServers = [
    "https://lyricsplus.prjktla.my.id", //youly's server
    "https://lyricsplus.atomix.one/", //meow's mirror
    "https://lyricsplus.binimum.org", //binimum's server
    "https://lyricsplus.prjktla.workers.dev", //ibra's cf worker
    "https://lyricsplus-seven.vercel.app", //jigen's mirror
    "https://lyrics-plus-backend.vercel.app", //ibra's vercel
  ];

  static String _normalizeBaseUrl(String baseUrl) {
    return baseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  static Uri _buildGetUri(
    String baseUrl, {
    required String title,
    required String artist,
    required String album,
    required String duration,
    bool useLegacyParamNames = false,
  }) {
    final normalizedBase = _normalizeBaseUrl(baseUrl);
    final qs = useLegacyParamNames
        ? 'artist_name=${Uri.encodeComponent(artist)}'
              '&track_name=${Uri.encodeComponent(title)}'
              '&album_name=${Uri.encodeComponent(album)}'
              '&duration=${Uri.encodeComponent(duration)}'
        : 'title=${Uri.encodeComponent(title)}'
              '&artist=${Uri.encodeComponent(artist)}'
              '&album=${Uri.encodeComponent(album)}'
              '&duration=${Uri.encodeComponent(duration)}';

    return Uri.parse(
      '$normalizedBase/v1/ttml/get?${qs.replaceAll('%20', '+')}',
    );
  }

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

    final body = await fetchFromKpoe(
      safeTitle,
      safeArtist,
      album: safeAlbum,
      duration: safeDuration,
      format: 'json',
    );

    if (body != null && body.isNotEmpty && body != "{}") {
      try {
        return LyricResult.fromJson(json.decode(body));
      } catch (_) {
        return null;
      }
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
        final marked = markInterSpanSpaces(ttml);
        final formatted = _formatXml(marked);
        final restored = restoreInterSpanSpaces(formatted);
        final collapsed = _collapseParagraphs(restored);
        return _normalizeTimestampsInString(_ensureXmlDeclaration(collapsed));
      }
      final ttml = _minimalTtmlFromText(
        jsonString,
        title: title,
        artist: artist,
        version: version,
      );
      final marked = markInterSpanSpaces(ttml);
      final formatted = _formatXml(marked);
      final restored = restoreInterSpanSpaces(formatted);
      final collapsed = _collapseParagraphs(restored);
      return _normalizeTimestampsInString(_ensureXmlDeclaration(collapsed));
    }

    if (root.containsKey('ttml') && root['ttml'] is String) {
      final rawTtml = root['ttml'] as String;
      final marked = markInterSpanSpaces(rawTtml);
      final formatted = _formatXml(marked);
      final restored = restoreInterSpanSpaces(formatted);
      final collapsed = _collapseParagraphs(restored);
      return _normalizeTimestampsInString(_ensureXmlDeclaration(collapsed));
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

    final marked = markInterSpanSpaces(sb.toString());
    final formatted = _formatXml(marked);
    final restored = restoreInterSpanSpaces(formatted);
    final collapsed = _collapseParagraphs(restored);
    return _normalizeTimestampsInString(_ensureXmlDeclaration(collapsed));
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
      // Normalize begin/end attributes into mm:ss.cc (00:00.00)
      String normalizeVal(String raw) {
        raw = raw.trim();
        try {
          if (raw.contains(':')) {
            final parts = raw.split(':');
            if (parts.length == 3) {
              // hh:mm:ss(.ms)
              final h = int.tryParse(parts[0]) ?? 0;
              final m = int.tryParse(parts[1]) ?? 0;
              final secPart = double.tryParse(parts[2]) ?? 0.0;
              final totalMs =
                  (h * 3600 * 1000) +
                  (m * 60 * 1000) +
                  (secPart * 1000).round();
              return _msToTimestamp(totalMs);
            } else if (parts.length == 2) {
              // mm:ss(.ms)
              final m = int.tryParse(parts[0]) ?? 0;
              final secPart = double.tryParse(parts[1]) ?? 0.0;
              final totalMs = (m * 60 * 1000) + (secPart * 1000).round();
              return _msToTimestamp(totalMs);
            }
          }
          // No colon: treat as seconds(.ms)
          final secVal = double.tryParse(raw) ?? 0.0;
          final totalMs = (secVal * 1000).round();
          return _msToTimestamp(totalMs);
        } catch (e) {
          return raw;
        }
      }

      return s.replaceAllMapped(
        RegExp(r'(?:\b(begin|end)\s*=\s*\")([^\"]+)(\")'),
        (m) {
          final attr = m.group(1)!;
          final raw = m.group(2)!;
          final norm = normalizeVal(raw);
          return '${attr}="${norm}"';
        },
      );
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

    final candidateBases = customBaseUrl == null
        ? _kpoeServers
        : [customBaseUrl];

    final headers = {
      'User-Agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36',
      'Accept': 'application/ttml+xml, application/xml, text/xml, */*',
    };

    for (final base in candidateBases) {
      final normalizedBase = _normalizeBaseUrl(base);
      if (_temporarilyDisabledBases.contains(normalizedBase)) {
        continue;
      }

      final urls = [
        _buildGetUri(
          base,
          title: safeTitle,
          artist: safeArtist,
          album: safeAlbum,
          duration: safeDuration,
        ),
        _buildGetUri(
          base,
          title: safeTitle,
          artist: safeArtist,
          album: safeAlbum,
          duration: safeDuration,
          useLegacyParamNames: true,
        ),
      ];

      for (final url in urls) {
        try {
          final r = await http.get(url, headers: headers);
          print('Kpoe GET $url -> ${r.statusCode} (len=${r.body.length})');
          if (r.statusCode == 200 && r.body.isNotEmpty && r.body != '{}') {
            return r.body;
          }
        } catch (e) {
          if (e is HandshakeException) {
            _temporarilyDisabledBases.add(normalizedBase);
            print(
              'Kpoe mirror disabled for this session due to TLS error: $normalizedBase',
            );
            break;
          }
          print('Kpoe fetch error at $url: $e');
        }
      }

      if (_temporarilyDisabledBases.contains(normalizedBase)) {
        continue;
      }
    }

    return null;
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
    // Convert milliseconds to mm:ss.cc (centiseconds) format like 00:00.00
    final totalMs = ms.toInt();
    // Round to nearest centisecond (10 ms)
    final totalCentis = (totalMs + 5) ~/ 10;
    final centis = totalCentis % 100;
    final totalSeconds = totalCentis ~/ 100;
    final sec = totalSeconds % 60;
    final min = totalSeconds ~/ 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${centis.toString().padLeft(2, '0')}';
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

  // Collapse each <p ...>...</p> block into a single line (no internal newlines)
  static String _collapseParagraphs(String s) {
    try {
      final re = RegExp(r'<p\b[^>]*?>.*?<\/p>', dotAll: true);
      return s.replaceAllMapped(re, (m) {
        var block = m.group(0) ?? '';
        block = block.replaceAll(RegExp(r'\s+'), ' ');
        return block.trim();
      });
    } catch (e) {
      return s;
    }
  }

  static Future<File> saveStringToDownloads(
    String filename,
    String content,
  ) async {
    try {
      // Pre-extract TTML (if JSON payload) so we can validate before any write.
      String preExtract = content;
      final extractedPre = _extractTtmlFromJson(content);
      if (extractedPre != null) preExtract = extractedPre;
      // Si parece TTML y contiene algún <p> sin <span> ni </span>, abortar guardado.
      if (_looksLikeTtml(preExtract) &&
          hasParagraphWithoutAnySpan(preExtract)) {
        throw _AbortSaveException(
          'TTML contiene <p> sin <span> ni </span>; abortando guardado',
        );
      }
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
        String toWrite = content;
        final extracted = _extractTtmlFromJson(content);
        if (extracted != null) toWrite = extracted;
        if (_looksLikeTtml(toWrite)) {
          toWrite = markInterSpanSpaces(toWrite);
          toWrite = _formatXml(toWrite);
          toWrite = restoreInterSpanSpaces(toWrite);
          toWrite = _collapseParagraphs(toWrite);
          toWrite = _isolateParagraphs(toWrite);
          toWrite = _ensureXmlDeclaration(toWrite);
          toWrite = _normalizeTimestampsInString(toWrite);
        }
        await file.writeAsString(toWrite, flush: true);
        return file;
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.create(recursive: true);
        String toWrite = content;
        final extracted2 = _extractTtmlFromJson(content);
        if (extracted2 != null) toWrite = extracted2;
        if (_looksLikeTtml(toWrite)) {
          toWrite = markInterSpanSpaces(toWrite);
          toWrite = _formatXml(toWrite);
          toWrite = restoreInterSpanSpaces(toWrite);
          toWrite = _collapseParagraphs(toWrite);
          toWrite = _isolateParagraphs(toWrite);
          toWrite = _ensureXmlDeclaration(toWrite);
          toWrite = _normalizeTimestampsInString(toWrite);
        }
        await file.writeAsString(toWrite, flush: true);
        return file;
      }
    } catch (e) {
      if (e is _AbortSaveException) rethrow;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$filename');
      await file.create(recursive: true);
      String toWrite = content;
      final extracted3 = _extractTtmlFromJson(content);
      if (extracted3 != null) toWrite = extracted3;
      if (_looksLikeTtml(toWrite)) {
        toWrite = markInterSpanSpaces(toWrite);
        toWrite = _formatXml(toWrite);
        toWrite = restoreInterSpanSpaces(toWrite);
        toWrite = _collapseParagraphs(toWrite);
        toWrite = _isolateParagraphs(toWrite);
        toWrite = _ensureXmlDeclaration(toWrite);
        toWrite = _normalizeTimestampsInString(toWrite);
      }
      await file.writeAsString(toWrite, flush: true);
      return file;
    }
  }

  static bool _looksLikeTtml(String s) {
    final trimmed = s.trimLeft();
    return trimmed.startsWith('<?xml') ||
        trimmed.startsWith('<tt') ||
        trimmed.contains('<tt ');
  }

  // Ensure each <p...>...</p> block appears on its own line and remove
  // stray internal newlines/extra spacing inside paragraphs.
  static String _isolateParagraphs(String s) {
    try {
      return s.replaceAllMapped(
        RegExp(r'<div[^>]*>([\s\S]*?)<\/div>', multiLine: true),
        (m) {
          final start = RegExp(
            r'<div[^>]*>',
          ).firstMatch(m.group(0)!)!.group(0)!;
          final inner = m.group(1) ?? '';
          final end = '</div>';
          final processed = inner.replaceAllMapped(
            RegExp(r'<p\b[^>]*>.*?<\/p>', dotAll: true),
            (pm) => pm.group(0)!.replaceAll(RegExp(r'\s+'), ' ').trim(),
          );
          // Put each paragraph on its own line
          final withLines = processed.replaceAllMapped(
            RegExp(r'(</p>)\s*(<p)', dotAll: true),
            (mm) => '${mm.group(1)}\n${mm.group(2)}',
          );
          return '$start$withLines$end';
        },
      );
    } catch (e) {
      return s;
    }
  }

  static String? _extractTtmlFromJson(String s) {
    try {
      final obj = json.decode(s);
      if (obj is Map && obj.containsKey('ttml') && obj['ttml'] is String) {
        return obj['ttml'] as String;
      }
    } catch (e) {
      // Not JSON or parse error: ignore
    }
    return null;
  }

  // Returns true if any <p ...>...</p> block contains NO <span> tags.
  static bool hasParagraphWithoutSpan(String s) {
    try {
      final re = RegExp(
        r'<p\b[^>]*>([\s\S]*?)<\/p>',
        dotAll: true,
        caseSensitive: false,
      );
      for (final m in re.allMatches(s)) {
        final inner = m.group(1) ?? '';
        if (!RegExp(r'<span\b', caseSensitive: false).hasMatch(inner)) {
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // Special exception to signal that save must be aborted without fallback write.
  // Caught and rethrown in saveStringToDownloads so fallback doesn't write the file.
  // Internal only.
  // (moved to top-level below)

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
      var out = sb.toString();
      out = _cleanupParagraphLinebreaks(out);
      return out;
    } catch (e) {
      return xml;
    }
  }

  // Asegura que no haya saltos de línea antes de </p> y que cada </p> vaya seguida
  // de un salto de línea para separar párrafos claramente.
  static String _cleanupParagraphLinebreaks(String s) {
    try {
      // Elimina saltos de línea y espacios antes de </p>
      s = s.replaceAll(RegExp(r'\n\s*</p>'), '</p>');
      // Si </p> quedó pegado a otra etiqueta de apertura, añade salto de línea
      s = s.replaceAll('</p><', '</p>\n<');
      return s;
    } catch (e) {
      return s;
    }
  }

  // Marca los lugares donde entre dos spans había espacios originalmente,
  // para preservarlos durante el formateo (que puede normalizar/eliminar
  // espacios entre etiquetas). Se usa un placeholder HTML comment.
  static String markInterSpanSpaces(String s) {
    try {
      // Inserta un marcador para preservar espacios entre spans.
      // Casos a cubrir:
      // 1) </span> <span  -> espacio literal entre dos spans
      // 2) </span><span...></span> <span -> un span vacío usado como separador
      // 3) >text</span> <span -> texto seguido de espacio y siguiente span
      var out = s;
      // empty separator span between two spans
      out = out.replaceAllMapped(
        RegExp(r'</span>\s*<span[^>]*>\s*</span>\s*<span', dotAll: true),
        (m) => '</span><!--SPL--><span',
      );
      // general closing span then whitespace then opening span
      out = out.replaceAllMapped(
        RegExp(r'</span>\s+<span'),
        (m) => '</span><!--SPL--><span',
      );
      // text inside span followed by space and next span
      out = out.replaceAllMapped(RegExp(r'>([^<]*)</span>\s+<span'), (m) {
        final inner = m.group(1) ?? '';
        return '>${inner}<!--SPL--></span><span';
      });
      return out;
    } catch (e) {
      return s;
    }
  }

  // Restaura el marcador por un espacio real después del formateo.
  static String restoreInterSpanSpaces(String s) {
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

// Special exception to signal that save must be aborted without fallback write.
// Caught and rethrown in saveStringToDownloads so fallback doesn't write the file.
// Internal only.
class _AbortSaveException implements Exception {
  final String message;
  _AbortSaveException(this.message);
  @override
  String toString() => 'AbortSaveException: $message';
}
