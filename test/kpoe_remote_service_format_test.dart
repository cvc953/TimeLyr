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
  });
}
