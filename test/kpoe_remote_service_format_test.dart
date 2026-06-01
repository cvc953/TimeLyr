import 'package:flutter_test/flutter_test.dart';
import 'package:timelyr/services/kpoe_remote_service.dart';

void main() {
  group('KpoeRemoteService TTML formatting', () {
    test('Cada línea debe comenzar con <p y terminar con </p>', () {
      final ttml = KpoeRemoteService.convertKpoeJsonToTtml('''{
  "ttml": "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\n<p begin='00:00.00' end='00:01.00'>Hola</p>\n<p begin='00:01.00' end='00:02.00'>Mundo</p>\n</div></body></tt>"
}''');
      final pLines = RegExp(r'<p[^>]*>.*?</p>').allMatches(ttml).toList();
      expect(pLines.length, greaterThanOrEqualTo(2));
      for (final m in pLines) {
        expect(m.group(0)!.trim().startsWith('<p'), isTrue);
        expect(m.group(0)!.trim().endsWith('</p>'), isTrue);
      }
    });

    test('Espacio entre spans se preserva', () {
      final xml = '<span>Hola</span> <span>mundo</span>';
      final marcado = KpoeRemoteService.markInterSpanSpaces(xml);
      final restaurado = KpoeRemoteService.restoreInterSpanSpaces(marcado);
      expect(restaurado, contains('<span>Hola</span> <span>mundo</span>'));
    });

    test('agregarEspacioEntreSpans agrega espacio correctamente', () {
      final xml =
          '<span>Hola</span><span>mundo</span> <span>cómo</span> <span>estás</span>';
      final result = KpoeRemoteService.agregarEspacioEntreSpans(xml);
      expect(result, contains('<span>mundo </span> <span>'));
      expect(result, contains('<span>cómo </span> <span>'));
    });

    test('convertTtmlToLrc extrae timestamps y texto de TTML', () {
      final ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml">
  <body>
    <div>
      <p begin="00:01.25" end="00:02.00"><span>Hola</span> <span>mundo</span></p>
      <p begin="00:03.50" end="00:04.00"><span>Qué</span> <span>tal</span></p>
    </div>
  </body>
</tt>
''';

      final lrc = KpoeRemoteService.convertTtmlToLrc(ttml);
      expect(lrc, contains('[00:01.25]Hola mundo'));
      expect(lrc, contains('[00:03.50]Qué tal'));
    });

    test('convertTtmlToLrc usa 00:00.00 cuando begin es inválido', () {
      final ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml">
  <body><div><p><span>Texto sin begin</span></p></div></body>
</tt>
''';
      final lrc = KpoeRemoteService.convertTtmlToLrc(ttml);
      expect(lrc, contains('[00:00.00]Texto sin begin'));
    });

    test('convertTtmlToLrc decodifica entidades XML y timestamps reales', () {
      final ttml =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<tt xmlns="http://www.w3.org/ns/ttml">'
          '<body><div>'
          '<p begin="00:00.010" end="00:01.670">Noi siamo chaos</p>'
          '<p begin="00:01.670" end="00:05.280">Il chaos perfetto, perfetto</p>'
          '<p begin="00:05.280" end="00:07.640">Tra spine e rose</p>'
          '<p begin="00:31.220" end="00:33.960">cuore nell&#x27;arsenico</p>'
          '<p begin="00:33.960" end="00:36.590">Per dimenticarci</p>'
          '</div></body></tt>';

      final lrc = KpoeRemoteService.convertTtmlToLrc(ttml);
      expect(lrc, contains('[00:00.01]Noi siamo chaos'));
      expect(lrc, contains('[00:01.67]Il chaos perfetto, perfetto'));
      expect(lrc, contains('[00:31.22]cuore nell\'arsenico'));
    });

    test('convertTtmlToLrc maneja formato hh:mm:ss.xxx', () {
      final ttml = '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="00:00:01.250" end="00:00:02.000">Uno</p>'
          '<p begin="00:01:30.500" end="00:01:32.000">Dos</p>'
          '</div></body></tt>';

      final lrc = KpoeRemoteService.convertTtmlToLrc(ttml);
      expect(lrc, contains('[00:01.25]Uno'));
      expect(lrc, contains('[01:30.50]Dos'));
    });

    test('convertTtmlToLrc maneja timestamps en segundos sin colon', () {
      final ttml = '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
          '<p begin="1.5">Uno</p>'
          '<p begin="90.0">Noventa</p>'
          '</div></body></tt>';

      final lrc = KpoeRemoteService.convertTtmlToLrc(ttml);
      expect(lrc, contains('[00:01.50]Uno'));
      expect(lrc, contains('[01:30.00]Noventa'));
    });
  });
}
