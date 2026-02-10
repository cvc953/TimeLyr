import 'package:flutter_test/flutter_test.dart';
import 'package:timelyr/services/kpoe_remote_service.dart';

void main() {
  group('KpoeRemoteService TTML formatting', () {
    test('Cada línea debe comenzar con <p y terminar con </p>', () {
      final ttml = KpoeRemoteService.convertKpoeJsonToTtml('''[
  {"time":0, "duration":1000, "text":"Hola"},
  {"time":1000, "duration":1000, "text":"Mundo"}
]''');
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
      expect(restaurado, contains('Hola </span> <span>mundo'));
    });

    test('agregarEspacioEntreSpans agrega espacio correctamente', () {
      final xml =
          '<span>Hola</span><span>mundo</span> <span>cómo</span> <span>estás</span>';
      final result = KpoeRemoteService.agregarEspacioEntreSpans(xml);
      expect(result, contains('mundo</span> <span>'));
      expect(result, contains('cómo</span> <span>'));
    });
  });
}
