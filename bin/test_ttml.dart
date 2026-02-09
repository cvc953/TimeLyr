import 'package:timelyr/services/kpoe_remote_service.dart';

void main() {
  final sample =
      '<p begin="01:00.909" end="01:03.728" itunes:key="L9" ttm:agent="v1">'
      '<span begin="01:00.909" end="01:01.482">Bur</span>'
      '<span begin="01:01.482" end="01:01.800">ning</span> '
      '<span begin="01:01.800" end="01:02.333">in</span> '
      '<span begin="01:02.333" end="01:02.565">my</span> '
      '<span begin="01:02.565" end="01:03.728">brain</span></p>';

  final ttml = KpoeRemoteService.convertKpoeJsonToTtml(sample);
  print('--- TTML OUTPUT START ---');
  print(ttml);
  print('--- TTML OUTPUT END ---');
}
