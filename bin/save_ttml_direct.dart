import 'dart:io';
import 'dart:convert';

String _markInterSpanSpaces(String s) {
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
}

String _restoreInterSpanSpaces(String s) => s.replaceAll('<!--SPL-->', ' ');

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

String _isolateParagraphs(String s) {
  try {
    return s.replaceAllMapped(
      RegExp(r'<div[^>]*>([\s\S]*?)<\/div>', multiLine: true),
      (m) {
        final start = RegExp(r'<div[^>]*>').firstMatch(m.group(0)!)!.group(0)!;
        final inner = m.group(1) ?? '';
        final end = '</div>';
        final processed = inner.replaceAllMapped(
          RegExp(r'<p\b[^>]*>.*?</p>', dotAll: true),
          (pm) => pm.group(0)!.replaceAll(RegExp(r'\s+'), ' ').trim(),
        );
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

int? _parseTimeToMs(String raw) {
  raw = raw.trim();
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

String _normalizeTimestampsInString(String s) {
  try {
    return s.replaceAllMapped(
      RegExp(r'(?:\b(begin|end)\s*=\s*\")([^\"]+)(\")'),
      (m) {
        final attr = m.group(1)!;
        final raw = m.group(2)!;
        final ms = _parseTimeToMs(raw);
        if (ms == null) return m.group(0)!;
        final t = _msToTimestamp(ms);
        return '${attr}="${t}"';
      },
    );
  } catch (e) {
    return s;
  }
}

void main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart bin/save_ttml_direct.dart /path/input.json /path/output.xml',
    );
    exit(2);
  }
  final inPath = args[0];
  final outPath = args[1];
  final f = File(inPath);
  if (!await f.exists()) {
    stderr.writeln('Input not found: $inPath');
    exit(2);
  }
  final content = await f.readAsString();
  String? ttml;
  try {
    final root = json.decode(content);
    if (root is Map && root.containsKey('ttml') && root['ttml'] is String) {
      ttml = root['ttml'] as String;
    }
  } catch (e) {
    // not JSON
  }
  if (ttml == null) {
    stderr.writeln('No ttml field found in JSON; aborting');
    exit(3);
  }
  var out = _markInterSpanSpaces(ttml);
  out = _formatXmlStandalone(out);
  out = _restoreInterSpanSpaces(out);
  out = _collapseParagraphs(out);
  out = _isolateParagraphs(out);
  out = _ensureXmlDeclaration(out);
  out = _normalizeTimestampsInString(out);
  await File(outPath).writeAsString(out);
  print('Wrote: $outPath');
}

String _formatXmlStandalone(String xml) {
  try {
    var s = xml.replaceAllMapped(RegExp(r'>(\s*)<'), (m) {
      final after = xml.substring(
        m.end,
        m.end + 5 > xml.length ? xml.length : m.end + 5,
      );
      if (after.startsWith('span')) return '><';
      final before = xml.substring(m.start - 6 < 0 ? 0 : m.start - 6, m.start);
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
        if (line.startsWith('</p')) sb.writeln();
        continue;
      }
      if (line.startsWith('<span')) {
        sb.write(line);
        continue;
      }
      final isSelfClosing = line.endsWith('/>');
      final isOpeningTag = line.startsWith('<') && !line.startsWith('</');
      sb.writeln('${indentStr(indent)}$line');
      if (isOpeningTag && !isSelfClosing && !line.startsWith('<?')) indent++;
    }
    var out = sb.toString();
    out = out.replaceAll(RegExp(r'\n\s*</p>'), '</p>');
    out = out.replaceAll('</p><', '</p>\n<');
    return out;
  } catch (e) {
    return xml;
  }
}
