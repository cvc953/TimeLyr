import 'dart:io';
import 'dart:convert';

// Minimal standalone runner that includes the conversion helpers
// copied/adapted from lib/services/kpoe_remote_service.dart

String convertKpoeJsonToTtml(String jsonString) {
  final trimmed = jsonString.trimLeft();
  if (trimmed.startsWith('<?xml') ||
      trimmed.startsWith('<tt') ||
      trimmed.startsWith('<!DOCTYPE')) {
    final ensured = _ensureXmlDeclaration(jsonString);
    final collapsed = _collapseParagraphs(ensured);
    return _normalizeTimestampsInString(collapsed);
  }

  Map<String, dynamic> root;
  try {
    root = json.decode(jsonString) as Map<String, dynamic>;
  } catch (e) {
    // fallback: return minimal wrapper
    return _ensureXmlDeclaration(_formatXml(_markInterSpanSpaces(jsonString)));
  }

  if (root.containsKey('ttml') && root['ttml'] is String) {
    final rawTtml = root['ttml'] as String;
    final marked = _markInterSpanSpaces(rawTtml);
    final formatted = _formatXml(marked);
    final restored = _restoreInterSpanSpaces(formatted);
    final collapsed = _collapseParagraphs(restored);
    return _normalizeTimestampsInString(_ensureXmlDeclaration(collapsed));
  }

  return jsonString;
}

String _ensureXmlDeclaration(String s) {
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

String _normalizeTimestampsInString(String s) {
  try {
    return s.replaceAllMapped(RegExp(r'(?:\b(begin|end)\s*=\s*\")([^\"]+)(\")'), (m) {
      final attr = m.group(1)!;
      final raw = m.group(2)!;
      final ms = _parseTimeToMs(raw);
      if (ms == null) return m.group(0)!; // leave unchanged
      final t = _msToTimestamp(ms);
      return '${attr}="${t}"';
    });
  } catch (e) {
    return s;
  }
}

int? _parseTimeToMs(String raw) {
  raw = raw.trim();
  // plain seconds: 12 or 12.34
  final dec = RegExp(r'^\d+(?:\.\d+)?$');
  if (dec.hasMatch(raw)) {
    final d = double.tryParse(raw);
    if (d == null) return null;
    return (d * 1000).round();
  }
  final parts = raw.split(':').map((p) => p.trim()).toList();
  if (parts.length == 2) {
    final mm = int.tryParse(parts[0]) ?? 0;
    final ss = double.tryParse(parts[1]) ?? 0.0;
    return (mm * 60000 + (ss * 1000)).round();
  }
  if (parts.length == 3) {
    final hh = int.tryParse(parts[0]) ?? 0;
    final mm = int.tryParse(parts[1]) ?? 0;
    final ss = double.tryParse(parts[2]) ?? 0.0;
    return (hh * 3600000 + mm * 60000 + (ss * 1000)).round();
  }
  return null;
}

String _msToTimestamp(int ms) {
  final totalSeconds = ms ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  final centis = ((ms % 1000) / 10).round();
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  final cc = centis.toString().padLeft(2, '0');
  return '$mm:$ss.$cc';
}

String _collapseParagraphs(String s) {
  try {
    return s.replaceAllMapped(RegExp(r'<p[^>]*>[\s\S]*?<\/p>'), (m) {
      var inner = m.group(0)!;
      inner = inner.replaceAll('\n', ' ');
      inner = inner.replaceAll(RegExp(r'\s+'), ' ');
      return inner.replaceAll(RegExp(r'>\s+<'), '><');
    });
  } catch (e) {
    return s;
  }
}

String _formatXml(String xml) {
  try {
    var s = xml.replaceAllMapped(RegExp(r'>(\s*)<'), (m) {
      final after = xml.substring(
        m.end,
        m.end + 5 > xml.length ? xml.length : m.end + 5,
      );
      if (after.startsWith('span')) return '><';
      final before = xml.substring(
        m.start - 6 < 0 ? 0 : m.start - 6,
        m.start,
      );
      if (before.endsWith('/span')) return '><';
      return '>\n<';
    });
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
        if (line.startsWith('</span')) {
          sb.write(line);
          continue;
        }
        sb.writeln('${indentStr(indent)}$line');
        if (line.startsWith('</p')) {
          sb.writeln();
        }
        continue;
      }
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

String _cleanupParagraphLinebreaks(String s) {
  try {
    s = s.replaceAll(RegExp(r'\n\s*</p>'), '</p>');
    s = s.replaceAll('</p><', '</p>\n<');
    return s;
  } catch (e) {
    return s;
  }
}

String _markInterSpanSpaces(String s) {
  try {
    return s.replaceAllMapped(RegExp(r'>([^<]*)</span>\s+<span'), (m) {
      final inner = m.group(1) ?? '';
      return '>${inner}<!--SPL--></span><span';
    });
  } catch (e) {
    return s;
  }
}

String _restoreInterSpanSpaces(String s) {
  try {
    return s.replaceAll('<!--SPL-->', ' ');
  } catch (e) {
    return s;
  }
}

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart bin/convert_ttml_runner.dart /path/to/input.json');
    exit(2);
  }
  final path = args[0];
  final input = File(path);
  if (!await input.exists()) {
    stderr.writeln('File not found: $path');
    exit(2);
  }
  final content = await input.readAsString();
  try {
    final out = convertKpoeJsonToTtml(content);
    print(out);
  } catch (e, st) {
    stderr.writeln('Conversion error: $e\n$st');
    exit(1);
  }
}
