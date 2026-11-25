import 'package:flutter_test/flutter_test.dart';
import 'package:timelyr/services/lrc_red_service.dart';

void main() {
  group('LrcRedTrack.fromSearchJson', () {
    test('parsea los campos de un hit de búsqueda', () {
      final track = LrcRedTrack.fromSearchJson({
        'isrc': 'USRC17607839',
        'title': 'Creep',
        'artist': 'Radiohead',
        'album': 'Pablo Honey',
        'year': 1993,
        'duration': 238.4,
        'cover': 'https://lrc.red/cover/creep.jpg',
        'color': '#123456',
      });

      expect(track.isrc, 'USRC17607839');
      expect(track.title, 'Creep');
      expect(track.artist, 'Radiohead');
      expect(track.album, 'Pablo Honey');
      expect(track.year, 1993);
      expect(track.durationSeconds, closeTo(238.4, 0.001));
      expect(track.coverUrl, 'https://lrc.red/cover/creep.jpg');
      expect(track.sync, isEmpty);
      expect(track.ttmlUrl, isEmpty);
      expect(track.lrcUrl, isEmpty);
      expect(track.pageUrl, isEmpty);
    });

    test('tolera campos ausentes o inválidos', () {
      final track = LrcRedTrack.fromSearchJson({
        'isrc': 'USRC17607839',
        'duration': 'desconocida',
      });

      expect(track.isrc, 'USRC17607839');
      expect(track.title, isEmpty);
      expect(track.artist, isEmpty);
      expect(track.album, isEmpty);
      expect(track.year, isNull);
      expect(track.durationSeconds, 0);
      expect(track.coverUrl, isEmpty);
    });
  });

  group('LrcRedTrack.fromTrackJson', () {
    test('parsea files.ttml, files.lrc, page y sync', () {
      final track = LrcRedTrack.fromTrackJson({
        'isrc': 'USRC17607839',
        'title': 'Creep',
        'artist': 'Radiohead',
        'album': 'Pablo Honey',
        'year': 1993,
        'duration': 238,
        'sync': 'word',
        'page': '/s/USRC17607839',
        'files': {
          'ttml': '/s/USRC17607839.ttml',
          'lrc': 'https://cdn.example.com/creep.lrc',
        },
      });

      expect(track.ttmlUrl, 'https://lrc.red/s/USRC17607839.ttml');
      expect(track.lrcUrl, 'https://cdn.example.com/creep.lrc');
      expect(track.pageUrl, 'https://lrc.red/s/USRC17607839');
      expect(track.sync, 'word');
      expect(track.durationSeconds, 238);
      expect(track.hasTtml, isTrue);
    });

    test('tolera la ausencia de files', () {
      final track = LrcRedTrack.fromTrackJson({'isrc': 'USRC17607839'});

      expect(track.ttmlUrl, isEmpty);
      expect(track.lrcUrl, isEmpty);
      expect(track.pageUrl, isEmpty);
      expect(track.hasTtml, isFalse);
      expect(track.sync, isEmpty);
    });
  });

  group('LrcRedService.selectBest', () {
    const exact = LrcRedTrack(
      isrc: 'EXACT',
      title: 'Creep',
      artist: 'Radiohead',
      album: 'Pablo Honey',
      year: 1993,
      durationSeconds: 238,
      sync: 'word',
    );
    const acoustic = LrcRedTrack(
      isrc: 'ACOUSTIC',
      title: 'Creep (Acoustic)',
      artist: 'Radiohead',
      album: 'Acoustic Hits',
      durationSeconds: 258,
    );
    const lenaHall = LrcRedTrack(
      isrc: 'LENA',
      title: 'Creep',
      artist: 'Lena Hall',
      durationSeconds: 212,
    );
    const elizaLumley = LrcRedTrack(
      isrc: 'ELIZA',
      title: 'Creep',
      artist: 'Eliza Lumley',
      durationSeconds: 301,
    );

    test('prefiere la coincidencia exacta de título, artista y duración', () {
      final best = LrcRedService.selectBest(
        [lenaHall, acoustic, exact, elizaLumley],
        title: 'Creep',
        artist: 'Radiohead',
        album: 'Pablo Honey',
        durationSeconds: 238,
      );

      expect(best, isNotNull);
      expect(best!.isrc, 'EXACT');
    });

    test('devuelve null cuando ningún resultado coincide', () {
      final best = LrcRedService.selectBest(
        [lenaHall, elizaLumley],
        title: 'Creep',
        artist: 'Radiohead',
        durationSeconds: 238,
      );

      expect(best, isNull);
    });
  });

  group('LrcRedService.scoreTrack', () {
    test('puntúa alto una coincidencia exacta', () {
      const track = LrcRedTrack(
        isrc: 'EXACT',
        title: 'Creep',
        artist: 'Radiohead',
        durationSeconds: 238,
      );

      final score = LrcRedService.scoreTrack(
        track,
        title: 'Creep',
        artist: 'Radiohead',
        durationSeconds: 238,
      );

      expect(score, greaterThanOrEqualTo(0.9));
    });

    test('puntúa bajo una coincidencia con artista y duración distintos', () {
      const track = LrcRedTrack(
        isrc: 'LENA',
        title: 'Creep',
        artist: 'Lena Hall',
        durationSeconds: 212,
      );

      final score = LrcRedService.scoreTrack(
        track,
        title: 'Creep',
        artist: 'Radiohead',
        durationSeconds: 238,
      );

      expect(score, lessThan(0.7));
    });
  });
}
